import SwiftUI
import HerdrManagerCore

/// What (if anything) is expanded under the currently-selected row. Owned by
/// `PanelView` (only one row is ever selected/expanded at a time) and passed
/// down so `AgentRow` stays a presentation layer plus action wiring.
enum RowExpansion: Equatable {
    case none
    case peekLoading
    case peek(String)
    case nudge
    case closeConfirm
}

struct AgentRow: View, Equatable {
    @Environment(AppModel.self) private var appModel
    let agent: Agent
    let dailyCost: TokenMeterSummary
    let isSelected: Bool
    let expansion: RowExpansion
    @Binding var nudgeText: String

    let onSelect: () -> Void
    let onJump: () -> Void
    let onPeekToggle: () -> Void
    let onNudgeOpen: () -> Void
    let onNudgeSubmit: () -> Void
    let onCloseRequest: () -> Void
    let onCloseConfirm: () -> Void
    let onCancelExpansion: () -> Void

    @State private var isHovering = false

    nonisolated static func == (lhs: AgentRow, rhs: AgentRow) -> Bool {
        lhs.agent == rhs.agent
            && lhs.dailyCost == rhs.dailyCost
            && lhs.isSelected == rhs.isSelected
            && (lhs.isSelected ? lhs.expansion == rhs.expansion : true)
    }

    private var kindLabel: String { agent.kind.label }

    /// The agent's own name when herdr gives it one; the row falls back to the
    /// kind so a nameless pane never renders a blank title.
    private var titleText: String {
        let name = agent.displayName.isEmpty ? agent.name : agent.displayName
        return name.isEmpty ? kindLabel : name
    }

    private var cwdBase: String {
        let c = agent.cwd
        guard !c.isEmpty else { return "" }
        return c.split(separator: "/").last.map(String.init) ?? c
    }

    private var locationLine: String {
        var parts: [String] = []
        // Keep the kind visible when the title is a terminal title rather than
        // the agent kind itself — the title line can't be the only place it lives.
        if titleText.lowercased() != kindLabel { parts.append(kindLabel) }
        if !agent.workspaceName.isEmpty { parts.append(agent.workspaceName) }
        if !agent.tabName.isEmpty { parts.append(agent.tabName) }
        if !cwdBase.isEmpty { parts.append("~\(cwdBase)") }
        return parts.joined(separator: " · ")
    }

    /// "blocked", "silent", "gone", "working", "done" — verdict overrides the
    /// raw herdr status when it's more informative (a "working" pane that's
    /// gone silent, or a pane whose process disappeared, reads better as
    /// "silent"/"gone" than as its stale raw status).
    private var stateLabel: String {
        if agent.verdict.isProcessGone { return "gone" }
        if agent.verdict.isSilent { return "silent" }
        return agent.status.rawValue
    }

    private var dwellString: String {
        DwellFormatter.format(enteredAt: agent.enteredAt)
    }

    private var reasonColor: Color {
        switch agent.verdict.reasonTone {
        case .danger: return Brand.blocked
        case .warn: return Brand.silent
        case .info: return Brand.done
        case .neutral: return .secondary
        }
    }

    private var accessibilityDescription: String {
        let reason = agent.verdict.reasonText ?? "no issues"
        let cost = dailyCost.hasUsage ? ", today \(UsageFormatter.cost(dailyCost)) API equivalent" : ""
        return "\(titleText), \(kindLabel), \(stateLabel), \(dwellString)\(cost), \(reason)"
    }

    /// The state as a tinted chip rather than plain grey text — at a glance the
    /// state now reads from the same colour as the row's rail and dot.
    private func statePill(accent: Color) -> some View {
        Text(stateLabel)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(accent.opacity(0.14)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.28), lineWidth: 0.5))
            .fixedSize()
    }

    var body: some View {
        let accent = Brand.color(for: agent)
        let active = (agent.status == .working || agent.status == .blocked)
        let alarmed = (agent.status == .blocked || agent.verdict.isProcessGone)

        HStack(alignment: .top, spacing: 0) {
            // Left status rail — the colour IS the state, glowing when active.
            Capsule()
                .fill(accent)
                .frame(width: 3.5)
                .padding(.vertical, 8)
                .shadow(color: accent.opacity(alarmed || active ? 0.75 : 0.25),
                        radius: alarmed ? 5 : (active ? 3 : 1.5))
                .padding(.trailing, 11)

            VStack(alignment: .leading, spacing: 4) {
                // Line 1: name/kind (left) + state pill and dwell (right).
                HStack(spacing: 7) {
                    StatusDot(color: accent, active: active)
                    Text(titleText)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    statePill(accent: accent)
                    Text(dwellString)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Line 2: workspace · tab · ~cwd-basename.
                if !locationLine.isEmpty {
                    Text(locationLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Line 3: what it's waiting on, only when there's something to say.
                if let reason = agent.verdict.reasonText {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(reasonColor)
                        .lineLimit(2)
                }

                if dailyCost.hasUsage {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                        Text("Today \(UsageFormatter.cost(dailyCost)) API equivalent")
                            .lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Brand.amber.opacity(0.9))
                }

                if isSelected {
                    actionRow
                    expansionView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .padding(.leading, 8)
        .background(cardBackground(accent: accent, active: active || alarmed))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Brand.amber.opacity(0.85)
                        : accent.opacity(isHovering ? 0.4 : 0.14),
                    lineWidth: isSelected ? 1.25 : 1
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .onTapGesture(count: 2) { onJump() }
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-click to jump to this agent")
        .contextMenu {
            Button("Override: 5 min") { appModel.setThresholdOverride(for: agent, minutes: 5) }
            Button("Override: 10 min") { appModel.setThresholdOverride(for: agent, minutes: 10) }
            Button("Override: 15 min") { appModel.setThresholdOverride(for: agent, minutes: 15) }
            Button("Override: 30 min") { appModel.setThresholdOverride(for: agent, minutes: 30) }
            Divider()
            Button("Reset to Default") { appModel.resetThresholdOverride(for: agent) }
        }
    }

    // MARK: - Action row (selected row only)

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 7) {
            if agent.verdict.isAwaitingInput {
                Button("Approve") { appModel.approve(agent) }
                    .help("Sends Enter to accept the highlighted option")
                Button("Deny") { appModel.deny(agent) }
                    .help("Sends Esc to dismiss the prompt")
            }
            Button("Peek") { onPeekToggle() }
                .help("Show the last 20 lines of this pane")
            Button("Jump") { onJump() }
                .help("Focus this agent's workspace and pane")
            Spacer(minLength: 0)
            Menu {
                Button("Nudge…") { onNudgeOpen() }
                Divider()
                Button("Close agent", role: .destructive) { onCloseRequest() }
            } label: {
                Text("⋯")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.system(size: 12))
        .padding(.top, 6)
    }

    // MARK: - Expansion (peek / nudge / close-confirm), selected row only

    @ViewBuilder
    private var expansionView: some View {
        switch expansion {
        case .none:
            EmptyView()
        case .peekLoading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        case .peek(let content):
            ScrollView {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 4)
        case .nudge:
            HStack(spacing: 6) {
                TextField("Send a message…", text: $nudgeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { onNudgeSubmit() }
                    .onExitCommand { onCancelExpansion() }
                Button("Send") { onNudgeSubmit() }
                    .controlSize(.regular)
            }
            .padding(.top, 4)
        case .closeConfirm:
            HStack(spacing: 8) {
                Text("Close agent?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.blocked)
                Spacer(minLength: 0)
                Button("Cancel") { onCancelExpansion() }
                    .controlSize(.regular)
                Button("Close", role: .destructive) { onCloseConfirm() }
                    .controlSize(.regular)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Card background

    private func cardBackground(accent: Color, active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0.025))
            if active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.08))
            }
        }
    }
}

/// A status light. Active agents (working/blocked) get a calm outer ring and a
/// brighter glow instead of a repeating animation — continuous animations inside
/// a `MenuBarExtra` window are a known cause of the panel flickering open/closed,
/// so emphasis here is purely static.
private struct StatusDot: View {
    let color: Color
    let active: Bool

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1)
                    .frame(width: 11, height: 11)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(active ? 0.9 : 0.4), radius: active ? 3 : 1)
        }
        .frame(width: 12, height: 12)
    }
}
