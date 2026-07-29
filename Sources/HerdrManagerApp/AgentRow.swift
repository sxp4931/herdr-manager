import SwiftUI
import HerdrManagerCore

struct AgentRow: View {
    @Environment(AppModel.self) private var appModel
    let agent: Agent
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                statusDot
                Text(agent.displayName.isEmpty ? agent.name : agent.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                kindBadge
                Spacer()
                Text(dwellString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let summary = agent.verdict.summaryLine {
                HStack(spacing: 8) {
                    Circle().fill(Color.clear).frame(width: 8, height: 8) // spacer to align with status dot
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
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

    // MARK: - Status dot

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    private var dotColor: Color {
        switch agent.status {
        case .blocked: return .red
        case .done: return .blue
        case .idle: return .green
        case .working: return .green
        case .unknown:
            if agent.verdict.isSilent { return .orange }
            return .gray
        }
    }

    // MARK: - Kind badge

    private var kindBadge: some View {
        Text(kindLabel)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(kindColor.opacity(0.15))
            .foregroundStyle(kindColor)
            .cornerRadius(3)
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
