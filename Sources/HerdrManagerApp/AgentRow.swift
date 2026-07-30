import SwiftUI
import HerdrManagerCore

struct AgentRow: View, Equatable {
    @Environment(AppModel.self) private var appModel
    let agent: Agent
    let isSelected: Bool

    @State private var isHovering = false

    nonisolated static func == (lhs: AgentRow, rhs: AgentRow) -> Bool {
        lhs.agent == rhs.agent && lhs.isSelected == rhs.isSelected
    }

    private var displayName: String {
        agent.displayName.isEmpty ? agent.name : agent.displayName
    }

    private var cwdBase: String {
        let c = agent.cwd
        guard !c.isEmpty else { return "" }
        return c.split(separator: "/").last.map(String.init) ?? c
    }

    private var reasonColor: Color {
        switch agent.verdict.reasonTone {
        case .danger: return Brand.blocked
        case .warn: return Brand.silent
        case .info: return Brand.done
        case .neutral: return .secondary
        }
    }

    /// Accessibility label conveying name, status, and diagnostic reason.
    private var accessibilityDescription: String {
        let name = displayName
        let status = agent.status.rawValue
        let reason = agent.verdict.reasonText ?? "no issues"
        return "\(name), \(status), \(reason)"
    }

    var body: some View {
        let accent = Brand.color(for: agent)
        let active = (agent.status == .working || agent.status == .blocked)
        let alarmed = (agent.status == .blocked || agent.verdict.isProcessGone)

        HStack(alignment: .top, spacing: 0) {
            // Left status rail — the colour IS the state, glowing when active.
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 6)
                .shadow(color: accent.opacity(alarmed || active ? 0.75 : 0.25),
                        radius: alarmed ? 5 : (active ? 3 : 1.5))
                .padding(.trailing, 9)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(color: accent, active: active)
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    kindChip
                    Spacer(minLength: 6)
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 8.5))
                        Text(dwellString)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }

                // The line that matters: *what* it's waiting on, in the state
                // colour so it reads instantly instead of as grey filler.
                if let reason = agent.verdict.reasonText {
                    Text(reason)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(reasonColor)
                        .lineLimit(1)
                }

                // Where it lives — extra context the old UI never showed.
                if !cwdBase.isEmpty {
                    Text(cwdBase)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.trailing, 10)
        }
        .padding(.leading, 6)
        .background(cardBackground(accent: accent, active: active || alarmed))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? Brand.amber.opacity(0.85)
                        : accent.opacity(isHovering ? 0.4 : 0.14),
                    lineWidth: isSelected ? 1.25 : 1
                )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .scaleEffect(isHovering ? 1.012 : 1.0)
        .shadow(color: .black.opacity(isHovering ? 0.18 : 0),
                radius: isHovering ? 6 : 0, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .focusable()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-click to focus this agent")
        .contextMenu {
            let paneId = agent.id.raw
            Button("Override: 5 min") {
                Task { try? await appModel.settingsStore.setOverride(paneId: paneId, minutes: 5) }
            }
            Button("Override: 10 min") {
                Task { try? await appModel.settingsStore.setOverride(paneId: paneId, minutes: 10) }
            }
            Button("Override: 15 min") {
                Task { try? await appModel.settingsStore.setOverride(paneId: paneId, minutes: 15) }
            }
            Button("Override: 30 min") {
                Task { try? await appModel.settingsStore.setOverride(paneId: paneId, minutes: 30) }
            }
            Divider()
            Button("Reset to Default") {
                Task { try? await appModel.settingsStore.removeOverride(paneId: paneId) }
            }
        }
    }

    // MARK: - Card background

    private func cardBackground(accent: Color, active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0.025))
            if active {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(0.08))
            }
        }
    }

    // MARK: - Kind chip

    private var kindChip: some View {
        Text(kindLabel)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(kindColor.opacity(0.16))
            .foregroundStyle(kindColor)
            .cornerRadius(4)
    }

    private var kindLabel: String {
        switch agent.kind {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        case .gemini: return "Gemini"
        case .custom(let s): return s.prefix(12).capitalized
        }
    }

    private var kindColor: Color {
        switch agent.kind {
        case .claude: return .orange
        case .codex: return .green
        case .opencode: return .blue
        case .aider: return .purple
        case .gemini: return .cyan
        case .custom: return .secondary
        }
    }

    // MARK: - Dwell

    private var dwellString: String {
        DwellFormatter.format(enteredAt: agent.enteredAt)
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
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(active ? 0.9 : 0.4), radius: active ? 3 : 1)
        }
        .frame(width: 12, height: 12)
    }
}
