import SwiftUI
import HerdrManagerCore

struct UsageDashboardView: View {
    @Environment(AppModel.self) private var appModel

    let onBack: () -> Void

    @State private var window: UsageWindow = .day
    @State private var showPricing = false
    @State private var pricingProvider: TokenMeterProvider = .codex
    @State private var pricingModelKey = ""
    @State private var inputPrice = ""
    @State private var cacheReadPrice = ""
    @State private var cacheWrite5mPrice = ""
    @State private var cacheWrite1hPrice = ""
    @State private var outputPrice = ""

    private let panelWidth: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            windowPicker
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    overallCard
                    providerSection
                    agentSection
                    pricingSection
                    explanation
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: panelWidth, height: 620)
        .onAppear {
            loadPricingFields()
            appModel.refreshUsageNow()
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
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.borderless)
            .help("Back to agents")

            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(Brand.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage & cost")
                    .font(.system(size: 15, weight: .bold))
                Text("API-equivalent list-price estimate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                appModel.refreshUsageNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
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

    private var overallCard: some View {
        let summary = appModel.usageSnapshot.overallSummary(for: window)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All local activity")
                        .font(.system(size: 12, weight: .semibold))
                    Text(window.longLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(UsageFormatter.cost(summary))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.amber)
            }
            HStack(spacing: 12) {
                Label(UsageFormatter.tokens(summary.usage.totalTokens), systemImage: "number")
                Label("\(summary.sessions) sessions", systemImage: "rectangle.stack")
                if summary.actions > 0 {
                    Label("\(summary.actions) actions", systemImage: "wrench.and.screwdriver")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if summary.hasUsage {
                Text(UsageFormatter.tokenBreakdown(summary))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let models = UsageFormatter.modelNames(summary) {
                    Text(models)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if summary.hasUnpricedUsage {
                    Text("One or more logged models have no configured price.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            } else {
                Text("No supported local session usage found in this window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Providers")
            let providers = TokenMeterProvider.allCases.filter {
                appModel.usageSnapshot.providerSummary(for: $0, window: window).hasUsage
            }
            if providers.isEmpty {
                Text("Claude, Codex, Kimi, and Grok logs will appear here when available.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(detectedModels, id: \.self) { model in
                                    Button(model) {
                                        pricingModelKey = model
                                        loadPricingFields()
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 9.5, design: .monospaced))
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
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 3)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func priceField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(width: 72)
        }
    }

    private func loadPricingFields() {
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
            return
        }
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
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let models = UsageFormatter.modelNames(summary) {
                    Text(models)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if summary.hasUnpricedUsage {
                    Text("model price missing")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
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
