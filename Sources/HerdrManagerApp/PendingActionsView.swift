import SwiftUI
import HerdrManagerCore

struct PendingActionsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let actions = appModel.pendingActions
        guard !actions.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack {
                    Text("Pending Actions (\(actions.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)

                ForEach(actions, id: \.actionId) { action in
                    actionRow(action)
                }
            }
        )
    }

    @ViewBuilder
    private func actionRow(_ action: PendingAction) -> some View {
        let summary = Self.summary(for: action)
        let expiresText = Self.expiresText(for: action)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let observed = action.observedStatus, !observed.isEmpty {
                            Text("observed: \(observed)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !expiresText.isEmpty {
                            Text(expiresText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                Button {
                    appModel.approveAction(action.actionId)
                } label: {
                    Text("OK")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Approve")

                Button {
                    appModel.denyAction(action.actionId)
                } label: {
                    Text("Deny")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Deny")
            }

            // Expandable redacted detail (params are already redacted by the store).
            if !action.params.isEmpty {
                let sortedKeys = action.params.keys.sorted()
                DisclosureGroup("params") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(sortedKeys, id: \.self) { key in
                            // Skip internal fingerprint/metadata keys.
                            if !key.hasPrefix("_fp_") {
                                let value = action.params[key] ?? ""
                                Text("\(key): \(value)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.top, 2)
                }
                .font(.system(size: 9, weight: .medium))
                .tint(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Deterministic summary

    /// Build a deterministic, tool-aware summary from explicit param keys.
    /// Never uses `params.values.first` (dictionary order is nondeterministic).
    private static func summary(for action: PendingAction) -> String {
        let target = action.params["target"]
            ?? action.params["pane_id"]
            ?? action.params["agent_id"]
            ?? ""
        let shortTarget = target.isEmpty ? action.actionId : shorten(target)

        switch action.tool {
        case "agent.say":
            return "Send text to \(shortTarget)"
        case "agent.answer":
            return "Answer \(shortTarget)"
        case "agent.interrupt":
            let level = action.params["level"] ?? "default"
            return "Interrupt \(shortTarget) (\(level))"
        case "agent.stop":
            return "Stop \(shortTarget)"
        case "session.spawn":
            let kind = action.params["kind"] ?? "agent"
            let path = action.params["repo_path"]
                ?? action.params["cwd"]
                ?? action.params["path"]
                ?? ""
            let shortPath = path.isEmpty ? "" : " in \(shorten(path))"
            return "Spawn \(kind)\(shortPath)"
        case "agent.focus":
            return "Focus \(shortTarget)"
        case "agent.send_keys":
            return "Send keys to \(shortTarget)"
        case "agent.prompt":
            return "Prompt \(shortTarget)"
        case "pane.close":
            return "Close \(shortTarget)"
        case "workspace.create":
            let cwd = action.params["cwd"] ?? ""
            return cwd.isEmpty ? "Create workspace" : "Create workspace in \(shorten(cwd))"
        case "agent.start":
            let kind = action.params["kind"] ?? "agent"
            return "Start \(kind) \(shortTarget)"
        default:
            return action.tool
        }
    }

    /// Format the remaining time until `expiresAt`. Returns "" if already past.
    private static func expiresText(for action: PendingAction) -> String {
        let remaining = action.expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return "expired" }
        let seconds = Int(remaining)
        if seconds >= 60 {
            return "\(seconds / 60)m\(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    /// Shorten a path or ID to its last two components for compact display.
    private static func shorten(_ s: String) -> String {
        let parts = s.split(separator: "/")
        if parts.count <= 2 { return s }
        return parts.suffix(2).joined(separator: "/")
    }
}
