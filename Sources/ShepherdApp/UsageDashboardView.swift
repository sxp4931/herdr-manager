import SwiftUI
import AppKit
import HerdrManagerCore

struct UsageDashboardView: View {
    @Environment(AppModel.self) private var appModel

    let onBack: () -> Void

    @State private var window: UsageWindow = .day
    @State private var modelFilter: String?
    @State private var showPricing = false
    @State private var pricingProvider: TokenMeterProvider = .codex
    @State private var pricingModelKey = ""
    @State private var inputPrice = ""
    @State private var cacheReadPrice = ""
    @State private var cacheWrite5mPrice = ""
    @State private var cacheWrite1hPrice = ""
    @State private var outputPrice = ""
    @State private var saveError: String?
    /// Transient confirmation after a successful pricing save.
    @State private var saveNotice: String?
    /// Set by "Set price" so the provider picker's onChange does not wipe the
    /// model id we are about to load. See `onChange(of: pricingProvider)`.
    @State private var coverWorkflowModel: String?
    /// Non-nil while the editor holds a provider-fallback suggestion that has
    /// not been saved — distinct from a loaded saved rate.
    @State private var pricingSuggestion: PricingSuggestion?
    @State private var pricingScrollToken = 0
    @FocusState private var pricingFocus: PricingFocus?

    private static let pricingSectionID = "pricing-editor"
    private static let uncoveredListCap = 5

    /// The dashboard is taller than the triage panel; cap it to the screen so
    /// a small or scaled display never clips the pricing section behind the
    /// window edge. The inner ScrollView absorbs the remaining height.
    private var panelHeight: CGFloat {
        let screen = PanelLayout.panelScreen?.visibleFrame.height ?? 900
        return min(620, max(400, screen - 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            windowPicker
            modelPicker
            Divider()
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 12) {
                        overallCard
                        modelSection
                        providerSection
                        agentSection
                        uncoveredSection
                        pricingSection
                            .id(Self.pricingSectionID)
                        explanation
                    }
                    .padding(14)
                    .onChange(of: pricingScrollToken) { _, _ in
                        // DisclosureGroup lays out its fields a beat after
                        // `showPricing` flips; scrolling or focusing earlier
                        // lands on the collapsed header.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(Self.pricingSectionID, anchor: .top)
                            pricingFocus = .inputPrice
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: PanelLayout.panelWidth, height: panelHeight)
        .onAppear {
            loadPricingFields()
            appModel.refreshUsageNow()
        }
        .onChange(of: window) { _, _ in
            modelFilter = nil
        }
        .onChange(of: pricingProvider) { _, _ in
            // "Set price" assigns provider then model in one gesture. This
            // handler is the picker path and would otherwise clear
            // `pricingModelKey` before the model id is applied.
            if let model = coverWorkflowModel {
                coverWorkflowModel = nil
                pricingModelKey = model
                loadSuggestedFallbackPricing()
                return
            }
            pricingModelKey = ""
            loadPricingFields()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Back to agents")
            .accessibilityLabel("Back to agents")

            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(Brand.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage & cost")
                    .font(.system(size: 15, weight: .bold))
                Text("API-equivalent list-price estimate")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.secondaryText)
                freshnessLabel
            }
            Spacer(minLength: 8)
            Button {
                appModel.refreshUsageNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var freshnessLabel: some View {
        let generatedAt = appModel.usageSnapshot.generatedAt
        let isUnread = generatedAt == .distantPast
        return Label(
            UsageFormatter.freshness(generatedAt),
            systemImage: isUnread ? "questionmark.circle" : "clock"
        )
        .font(.system(size: 10))
        .foregroundStyle(Brand.secondaryText)
        .labelStyle(.titleAndIcon)
        .help(isUnread
              ? "No usage snapshot has been read yet"
              : "When this usage snapshot was generated")
    }

    private var windowPicker: some View {
        Picker("Window", selection: $window) {
            ForEach(UsageWindow.allCases) { window in
                Text(window.shortLabel).tag(window)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Models with usage in the current window, sorted by cost descending.
    private var modelsInWindow: [String] {
        appModel.usageSnapshot.models(withUsageIn: window)
            .sorted { left, right in
                let leftCost = appModel.usageSnapshot
                    .modelSummary(for: left, window: window).costUSD ?? 0
                let rightCost = appModel.usageSnapshot
                    .modelSummary(for: right, window: window).costUSD ?? 0
                return leftCost > rightCost
            }
    }

    /// Window total used as the share bar's single denominator. Nil or zero
    /// means there is nothing honest to proportion against — no bar, no %.
    private var windowCostUSD: Double? {
        appModel.usageSnapshot.overallSummary(for: window).costUSD
    }

    private func costShare(for summary: TokenMeterSummary) -> Double? {
        guard let cost = summary.costUSD,
              let total = windowCostUSD,
              total > 0 else {
            return nil
        }
        return min(1, max(0, cost / total))
    }

    private var modelPicker: some View {
        let models = modelsInWindow
        return HStack(spacing: 8) {
            Image(systemName: "cube")
                .font(.system(size: 11))
                .foregroundStyle(Brand.secondaryText)
            Picker("Model", selection: $modelFilter) {
                Text("All models").tag(String?.none)
                ForEach(models, id: \.self) { model in
                    Text(model).tag(Optional(model))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            if modelFilter != nil {
                Button {
                    self.modelFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.borderless)
                .help("Clear model filter")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var overallCard: some View {
        let summary: TokenMeterSummary
        if let modelFilter {
            summary = appModel.usageSnapshot.modelSummary(for: modelFilter, window: window)
        } else {
            summary = appModel.usageSnapshot.overallSummary(for: window)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelFilter ?? "All local activity")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(window.longLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageFormatter.cost(summary))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Brand.amber)
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                    Text("Estimate — not a bill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(UsageFormatter.cost(summary)), estimate, not a bill"
                )
            }
            HStack(spacing: 12) {
                Label(UsageFormatter.tokens(summary.usage.totalTokens), systemImage: "number")
                Label("\(summary.sessions) sessions", systemImage: "rectangle.stack")
                if summary.actions > 0 {
                    Label("\(summary.actions) actions", systemImage: "wrench.and.screwdriver")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Brand.secondaryText)
            if summary.hasUsage {
                Text(UsageFormatter.tokenBreakdown(summary))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Brand.secondaryText)
                if let models = UsageFormatter.modelNames(summary) {
                    Text(models)
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                }
                if summary.hasUnpricedUsage {
                    Label(
                        "One or more logged models have no configured price.",
                        systemImage: "tag.slash"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.warn)
                }
            } else {
                Text("No supported local session usage found in this window.")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.amber.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Brand.amber.opacity(0.25), lineWidth: 1)
        )
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Models")
            let models = modelsInWindow
            if models.isEmpty {
                Text("Per-model totals appear when a session log records a model id.")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(models.enumerated()), id: \.element) { index, model in
                    let summary = appModel.usageSnapshot
                        .modelSummary(for: model, window: window)
                    ModelUsageRow(
                        rank: index + 1,
                        model: model,
                        subtitle: UsageFormatter.tokenBreakdown(summary),
                        summary: summary,
                        share: costShare(for: summary),
                        isLeading: index == 0
                    )
                }
            }
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Providers")
            let providers = TokenMeterProvider.allCases.filter {
                appModel.usageSnapshot.providerSummary(for: $0, window: window).hasUsage
            }
            if providers.isEmpty {
                Text("Claude, Codex, DeepSeek, Qwen, Kimi, and Grok logs will appear here when available.")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.vertical, 4)
            } else {
                ForEach(providers) { provider in
                    UsageSummaryRow(
                        title: provider.displayName,
                        subtitle: UsageFormatter.tokenBreakdown(
                            appModel.usageSnapshot.providerSummary(for: provider, window: window)
                        ),
                        summary: appModel.usageSnapshot.providerSummary(for: provider, window: window)
                    )
                }
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Current agents")
            let agents = appModel.store.agents.values
                .filter { appModel.usageSnapshot.agentSummary(for: $0.id, window: window).hasUsage }
                .sorted {
                    let left = appModel.usageSnapshot.agentSummary(for: $0.id, window: window).costUSD ?? 0
                    let right = appModel.usageSnapshot.agentSummary(for: $1.id, window: window).costUSD ?? 0
                    return left > right
                }
            if agents.isEmpty {
                Text("Per-agent totals appear when a session log's working directory matches an active pane.")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.vertical, 4)
            } else {
                ForEach(agents) { agent in
                    AgentUsageRow(
                        agent: agent,
                        summary: appModel.usageSnapshot.agentSummary(for: agent.id, window: window)
                    )
                }
            }
            if appModel.usageSnapshot.ambiguousAttributionCount > 0 {
                Label(
                    "Some sessions share a working directory and were left unattributed.",
                    systemImage: "questionmark.circle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Brand.secondaryText)
            }
        }
    }

    /// Logged models with usage in this window and no model-specific price.
    /// They drop out of the dollar total until the user covers them.
    private var uncoveredModels: [UncoveredModel] {
        var seen: Set<String> = []
        var result: [UncoveredModel] = []
        for provider in TokenMeterProvider.allCases {
            for model in appModel.usageSnapshot.knownModels(for: provider) {
                let key = "\(provider.rawValue):\(model)"
                guard seen.insert(key).inserted else { continue }
                let summary = appModel.usageSnapshot.modelSummary(for: model, window: window)
                guard summary.hasUsage,
                      appModel.tokenMeterPriceBook.pricing(for: provider, model: model) == nil
                else { continue }
                result.append(UncoveredModel(provider: provider, model: model, summary: summary))
            }
        }
        return result.sorted {
            if $0.summary.usage.totalTokens != $1.summary.usage.totalTokens {
                return $0.summary.usage.totalTokens > $1.summary.usage.totalTokens
            }
            if $0.model != $1.model {
                return $0.model < $1.model
            }
            return $0.provider.rawValue < $1.provider.rawValue
        }
    }

    @ViewBuilder
    private var uncoveredSection: some View {
        let uncovered = uncoveredModels
        if !uncovered.isEmpty {
            let visible = Array(uncovered.prefix(Self.uncoveredListCap))
            let remaining = uncovered.count - visible.count
            VStack(alignment: .leading, spacing: 8) {
                Label("Not yet priced", systemImage: "tag.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.warn)
                Text("These models appear in the logs but have no configured price, so they are left out of the dollar total.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(visible) { item in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.model)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.model)
                            Text("\(item.provider.displayName) · \(UsageFormatter.tokens(item.summary.usage.totalTokens)) tokens")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Brand.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button("Set price") {
                            beginCoverPricing(provider: item.provider, model: item.model)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Set price for \(item.model)")
                        .help("Open the pricing editor with a suggested starting point for \(item.model)")
                    }
                }
                if remaining > 0 {
                    Text("+\(remaining) more")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Brand.warn.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Brand.warn.opacity(0.25), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Not yet priced")
        }
    }

    private var pricingSection: some View {
        DisclosureGroup("Configure model prices and fallbacks", isExpanded: $showPricing) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Provider", selection: $pricingProvider) {
                    ForEach(TokenMeterProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Provider")

                HStack(spacing: 6) {
                    TextField(
                        "Model ID / fragment (blank = provider fallback)",
                        text: $pricingModelKey
                    )
                    .textFieldStyle(.roundedBorder)
                    Button("Load") { loadPricingFields() }
                        .controlSize(.small)
                        .accessibilityLabel("Load saved price")
                }

                let detectedModels = appModel.usageSnapshot.knownModels(for: pricingProvider)
                if !detectedModels.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Detected models")
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.secondaryText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(detectedModels, id: \.self) { model in
                                    Button(model) {
                                        pricingModelKey = model
                                        loadPricingFields()
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 10, design: .monospaced))
                                    .accessibilityLabel("Load \(model)")
                                }
                            }
                        }
                    }
                }

                if let pricingSuggestion {
                    Label(pricingSuggestion.message, systemImage: "lightbulb")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Brand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(pricingSuggestion.message)
                }

                HStack(spacing: 6) {
                    priceField("Input", text: $inputPrice, focus: .inputPrice)
                    priceField("Cache read", text: $cacheReadPrice)
                    priceField("5m write", text: $cacheWrite5mPrice)
                    priceField("1h write", text: $cacheWrite1hPrice)
                    priceField("Output", text: $outputPrice)
                }
                HStack {
                    Text("USD per 1M tokens · unknown logged models remain n/a")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.secondaryText)
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.blocked)
                    } else if let saveNotice {
                        Text(saveNotice)
                            .font(.system(size: 10))
                            .foregroundStyle(Brand.working)
                    }
                    Spacer()
                    Button("Save") { savePricing() }
                        .controlSize(.small)
                        .accessibilityLabel("Save prices")
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 11.5, weight: .semibold))
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this is counted")
                .font(.system(size: 11.5, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("Reads local CLI logs only.")
                Text("A tilde means the source logged totals without an input/output split.")
                Text("“partial” means a model price is missing.")
                Text("Subscription marginal cost is still $0 — the dollar figure is what the same tokens would cost at the configured API list rates.")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Brand.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 3)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(Brand.secondaryText)
    }

    private func priceField(
        _ label: String,
        text: Binding<String>,
        focus: PricingFocus? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
            Group {
                if let focus {
                    TextField("0", text: text)
                        .focused($pricingFocus, equals: focus)
                } else {
                    TextField("0", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10.5, design: .monospaced))
            .frame(width: 72)
            .accessibilityLabel("\(label) price per million tokens")
        }
    }

    /// Jump the editor to an uncovered model and prefill the provider
    /// fallback as a suggestion — never as an applied rate.
    private func beginCoverPricing(provider: TokenMeterProvider, model: String) {
        saveError = nil
        saveNotice = nil
        showPricing = true
        if pricingProvider == provider {
            coverWorkflowModel = nil
            pricingModelKey = model
            loadSuggestedFallbackPricing()
        } else {
            coverWorkflowModel = model
            pricingProvider = provider
        }
        pricingScrollToken += 1
    }

    private func loadSuggestedFallbackPricing() {
        saveNotice = nil
        guard let pricing = appModel.tokenMeterPriceBook.pricing(
            for: pricingProvider,
            model: nil
        ) else {
            clearPricingFields()
            pricingSuggestion = .noneAvailable
            return
        }
        applyPricingToFields(pricing)
        pricingSuggestion = .providerFallback
    }

    private func loadPricingFields() {
        saveNotice = nil
        pricingSuggestion = nil
        let model = pricingModelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pricing = appModel.tokenMeterPriceBook.pricing(
            for: pricingProvider,
            model: model.isEmpty ? nil : model
        ) else {
            clearPricingFields()
            return
        }
        applyPricingToFields(pricing)
    }

    private func applyPricingToFields(_ pricing: TokenMeterPricing) {
        inputPrice = String(pricing.inputPerMillion)
        cacheReadPrice = String(pricing.cacheReadPerMillion)
        cacheWrite5mPrice = String(pricing.cacheWrite5mPerMillion)
        cacheWrite1hPrice = String(pricing.cacheWrite1hPerMillion)
        outputPrice = String(pricing.outputPerMillion)
    }

    private func clearPricingFields() {
        inputPrice = ""
        cacheReadPrice = ""
        cacheWrite5mPrice = ""
        cacheWrite1hPrice = ""
        outputPrice = ""
    }

    private func savePricing() {
        guard let input = Double(inputPrice), input >= 0,
              let cacheRead = Double(cacheReadPrice), cacheRead >= 0,
              let cacheWrite5m = Double(cacheWrite5mPrice), cacheWrite5m >= 0,
              let cacheWrite1h = Double(cacheWrite1hPrice), cacheWrite1h >= 0,
              let output = Double(outputPrice), output >= 0 else {
            saveNotice = nil
            saveError = "Enter valid prices in all fields"
            return
        }
        saveError = nil
        let pricing = TokenMeterPricing(
            inputPerMillion: input,
            cacheReadPerMillion: cacheRead,
            cacheWrite5mPerMillion: cacheWrite5m,
            cacheWrite1hPerMillion: cacheWrite1h,
            outputPerMillion: output
        )
        let model = pricingModelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            appModel.updateTokenMeterPricing(provider: pricingProvider, pricing: pricing)
        } else {
            appModel.updateTokenMeterModelPricing(
                provider: pricingProvider,
                model: model,
                pricing: pricing
            )
        }
        pricingSuggestion = nil
        saveNotice = "Saved"
        Task {
            try? await Task.sleep(for: .seconds(2))
            if saveNotice == "Saved" { saveNotice = nil }
        }
    }
}

private enum PricingFocus: Hashable {
    case inputPrice
}

/// Prefill source for the cover-this-model editor. Neither case is a saved rate.
private enum PricingSuggestion {
    case providerFallback
    case noneAvailable

    var message: String {
        switch self {
        case .providerFallback:
            return "Suggested starting point from the provider fallback — not applied to any figure until you Save."
        case .noneAvailable:
            return "No provider fallback is configured. Enter list rates and Save to cover this model."
        }
    }
}

private struct UncoveredModel: Identifiable {
    let provider: TokenMeterProvider
    let model: String
    let summary: TokenMeterSummary

    var id: String { "\(provider.rawValue):\(model)" }
}

private struct ModelUsageRow: View {
    let rank: Int
    let model: String
    let subtitle: String
    let summary: TokenMeterSummary
    let share: Double?
    let isLeading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(rank)")
                .font(.system(
                    size: isLeading ? 13 : 11,
                    weight: isLeading ? .bold : .semibold,
                    design: .rounded
                ))
                .monospacedDigit()
                .foregroundStyle(isLeading ? Brand.amber : Brand.secondaryText)
                .frame(width: 18, alignment: .trailing)
                .accessibilityLabel("Rank \(rank)")

            VStack(alignment: .leading, spacing: 2) {
                Text(model)
                    .font(.system(
                        size: isLeading ? 13.5 : 12,
                        weight: isLeading ? .bold : .semibold
                    ))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model)
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if summary.costUSD != nil {
                    Text(UsageFormatter.cost(summary))
                        .font(.system(
                            size: isLeading ? 14 : 12.5,
                            weight: isLeading ? .bold : .semibold,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Label("price missing", systemImage: "tag.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.warn)
                        .labelStyle(.titleAndIcon)
                }

                if let share {
                    HStack(spacing: 6) {
                        if share > 0 {
                            CostShareBar(share: share)
                        }
                        Text(UsageFormatter.costSharePercent(share))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Brand.secondaryText)
                            .monospacedDigit()
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(UsageFormatter.costSharePercent(share)) of window cost"
                    )
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, isLeading ? 9 : 7)
        .background(Color.primary.opacity(isLeading ? 0.07 : 0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Track width is fixed so every row's 100% is the same number of points.
/// The fill is proportional to the window total; a nil/zero total never
/// reaches this view, so we never draw a full bar for "unknown".
private struct CostShareBar: View {
    let share: Double

    private static let width: CGFloat = 72
    private static let height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Brand.amber)
                    .frame(width: max(2, geo.size.width * share))
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityHidden(true)
    }
}

private struct UsageSummaryRow: View {
    let title: String
    let subtitle: String
    let summary: TokenMeterSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
                if let models = UsageFormatter.modelNames(summary) {
                    Text(models)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }
                if summary.hasUnpricedUsage {
                    Text("model price missing")
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.warn)
                }
            }
            Spacer(minLength: 8)
            Text(UsageFormatter.cost(summary))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AgentUsageRow: View {
    let agent: Agent
    let summary: TokenMeterSummary

    private var title: String {
        let name = agent.displayName.isEmpty ? agent.name : agent.displayName
        return name.isEmpty ? agent.kind.label : name
    }

    var body: some View {
        UsageSummaryRow(
            title: title,
            subtitle: "\(agent.kind.label) · \(UsageFormatter.tokenBreakdown(summary))",
            summary: summary
        )
    }
}
