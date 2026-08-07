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
                VStack(alignment: .leading, spacing: 12) {
                    overallCard
                    modelSection
                    providerSection
                    agentSection
                    pricingSection
                    explanation
                }
                .padding(14)
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelFilter ?? "All local activity")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(window.longLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.secondaryText)
                }
                Spacer()
                Text(UsageFormatter.cost(summary))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.amber)
            }
            Text("Estimate — not a bill")
                .font(.system(size: 10))
                .foregroundStyle(Brand.secondaryText)
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
                    Text("One or more logged models have no configured price.")
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
                ForEach(models, id: \.self) { model in
                    UsageSummaryRow(
                        title: model,
                        subtitle: UsageFormatter.tokenBreakdown(
                            appModel.usageSnapshot.modelSummary(for: model, window: window)
                        ),
                        summary: appModel.usageSnapshot.modelSummary(for: model, window: window)
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

                HStack(spacing: 6) {
                    TextField(
                        "Model ID / fragment (blank = provider fallback)",
                        text: $pricingModelKey
                    )
                    .textFieldStyle(.roundedBorder)
                    Button("Load") { loadPricingFields() }
                        .controlSize(.small)
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
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    priceField("Input", text: $inputPrice)
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
            Text("Reads local CLI logs only. A tilde means the source logged totals without an input/output split; “partial” means a model price is missing. Subscription marginal cost is still $0—the dollar figure is what the same tokens would cost at the configured API list rates.")
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

    private func priceField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(width: 72)
        }
    }

    private func loadPricingFields() {
        saveNotice = nil
        let model = pricingModelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pricing = appModel.tokenMeterPriceBook.pricing(
            for: pricingProvider,
            model: model.isEmpty ? nil : model
        ) else {
            inputPrice = ""
            cacheReadPrice = ""
            cacheWrite5mPrice = ""
            cacheWrite1hPrice = ""
            outputPrice = ""
            return
        }
        inputPrice = String(pricing.inputPerMillion)
        cacheReadPrice = String(pricing.cacheReadPerMillion)
        cacheWrite5mPrice = String(pricing.cacheWrite5mPerMillion)
        cacheWrite1hPrice = String(pricing.cacheWrite1hPerMillion)
        outputPrice = String(pricing.outputPerMillion)
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
        saveNotice = "Saved"
        Task {
            try? await Task.sleep(for: .seconds(2))
            if saveNotice == "Saved" { saveNotice = nil }
        }
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
