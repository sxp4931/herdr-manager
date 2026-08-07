import SwiftUI
import HerdrManagerCore

struct PendingActionsView: View {
    @Environment(AppModel.self) private var appModel

    /// ID of the pending action currently awaiting an inline destructive
    /// confirmation (for tools that stop/close/interrupt). `nil` when no
    /// confirmation is armed.
    @State private var confirmingActionId: String?

    /// Tools whose approve/deny is destructive and needs an inline confirm.
    private static let destructiveTools: Set<String> = [
        "pane.close", "agent.stop", "agent.interrupt",
    ]

    private static func isDestructive(_ tool: String) -> Bool {
        destructiveTools.contains(tool)
    }

    var body: some View {
        let actions = appModel.pendingActions
        guard !actions.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack {
                    Text("Pending Actions (\(actions.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.warn)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)

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

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(summary)
                    HStack(spacing: 4) {
                        if let observed = action.observedStatus, !observed.isEmpty {
                            Text("observed: \(observed)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !expiresText.isEmpty {
                            Text(expiresText)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Brand.warn)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.actionAccessibilityLabel(summary: summary, observed: action.observedStatus, expires: expiresText))
                Spacer(minLength: 4)
                actionButtons(for: action)
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
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help("\(key): \(value)")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.top, 2)
                }
                .font(.system(size: 10.5, weight: .medium))
                .tint(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private func actionButtons(for action: PendingAction) -> some View {
        let destructive = Self.isDestructive(action.tool)
        if destructive && confirmingActionId == action.actionId {
            // Inline confirmation for destructive tools: arm, then confirm or cancel.
            HStack(spacing: 6) {
                Button("Confirm Approve") { appModel.approveAction(action.actionId) }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.approveFill)
                    .controlSize(.regular)
                    .help(Self.approveHelp(for: action))
                Button("Confirm Deny") { appModel.denyAction(action.actionId) }
                    .buttonStyle(.bordered)
                    .tint(Brand.blocked)
                    .controlSize(.regular)
                    .help(Self.denyHelp(for: action))
                Button("Cancel") { confirmingActionId = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        } else {
            Button {
                if destructive {
                    confirmingActionId = action.actionId
                } else {
                    appModel.approveAction(action.actionId)
                }
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.approveFill)
            .controlSize(.regular)
            .help(Self.approveHelp(for: action))

            Button {
                if destructive {
                    confirmingActionId = action.actionId
                } else {
                    appModel.denyAction(action.actionId)
                }
            } label: {
                Label("Deny", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(Brand.blocked)
            .controlSize(.regular)
            .help(Self.denyHelp(for: action))
        }
    }

    private static func approveHelp(for action: PendingAction) -> String {
        switch action.tool {
        case "pane.close": return "Approve — closes the pane"
        case "agent.stop": return "Approve — stops the agent"
        case "agent.interrupt": return "Approve — interrupts the agent"
        case "session.spawn": return "Approve — spawns the agent"
        case "agent.say": return "Approve — sends the text"
        default: return "Approve — accepts this action"
        }
    }

    private static func denyHelp(for action: PendingAction) -> String {
        switch action.tool {
        case "pane.close": return "Deny — keeps the pane open"
        case "agent.stop": return "Deny — keeps the agent running"
        case "agent.interrupt": return "Deny — does not interrupt"
        default: return "Deny — rejects this action"
        }
    }

    // MARK: - Deterministic summary

    /// One VoiceOver label for the whole action row summary: the tool
    /// summary plus observed status and expiry, so a screen-reader user gets
    /// the same picture as a sighted user without hopping between fragments.
    private static func actionAccessibilityLabel(summary: String, observed: String?, expires: String) -> String {
        var parts = [summary]
        if let observed, !observed.isEmpty { parts.append("observed \(observed)") }
        if !expires.isEmpty { parts.append("expires \(expires)") }
        return parts.joined(separator: ", ")
    }

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
        let totalSeconds = Int(remaining)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m\(seconds)s"
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
