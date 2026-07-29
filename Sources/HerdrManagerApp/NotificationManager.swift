import Foundation
import UserNotifications
import HerdrManagerCore

@MainActor
final class NotificationManager {
    /// Tracks (paneId, seq) pairs we've already notified for, to avoid duplicates.
    private var notifiedKeys: Set<String> = []

    /// UNUserNotificationCenter requires a proper app bundle. When running as a
    /// bare SPM executable there is no bundle, so we guard every access.
    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center = notificationCenter else {
            print("[HerdrManager] No app bundle — notifications disabled (run via HerdrManager.app)")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[HerdrManager] Notification auth error: \(error)")
            }
            if granted {
                print("[HerdrManager] Notification permission granted")
            }
        }
    }

    /// Post a blocked notification for the agent. Returns true if a notification was posted.
    @discardableResult
    func notifyBlocked(agent: Agent, seq: UInt64?) -> Bool {
        let key = "\(agent.id.raw):\(seq ?? 0)"
        guard !notifiedKeys.contains(key) else { return false }
        notifiedKeys.insert(key)

        // Prune old keys if we accumulate too many
        if notifiedKeys.count > 500 {
            let arr = Array(notifiedKeys)
            let keep = Set(arr.suffix(250))
            notifiedKeys = keep
        }

        guard let center = notificationCenter else {
            // Fallback: print to console when running without a bundle
            print("[HerdrManager] 🔴 \(agent.displayName.isEmpty ? agent.name : agent.displayName) blocked — \(agent.workspaceName)/\(agent.tabName)")
            return true
        }

        let content = UNMutableNotificationContent()
        content.title = "🔴 \(agent.displayName.isEmpty ? agent.name : agent.displayName) blocked"
        content.body = "\(agent.workspaceName)/\(agent.tabName) — waiting for input"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "herdr-blocked-\(agent.id.raw)-\(seq ?? 0)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                print("[HerdrManager] Notification post error: \(error)")
            }
        }

        return true
    }

    /// Post a silent-agent notification. Returns true if a notification was posted.
    @discardableResult
    func notifySilent(agent: Agent) -> Bool {
        let key = "silent:\(agent.id.raw)"
        guard !notifiedKeys.contains(key) else { return false }
        notifiedKeys.insert(key)

        // Prune old keys if we accumulate too many
        if notifiedKeys.count > 500 {
            let arr = Array(notifiedKeys)
            let keep = Set(arr.suffix(250))
            notifiedKeys = keep
        }

        let elapsed: String
        if case .silent(let since, _) = agent.verdict {
            let totalSeconds = Int(Date().timeIntervalSince(since))
            let minutes = totalSeconds / 60
            if minutes >= 60 {
                elapsed = "\(minutes / 60)h\(minutes % 60)m"
            } else {
                elapsed = "\(minutes)m"
            }
        } else {
            elapsed = "unknown"
        }

        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName

        guard let center = notificationCenter else {
            print("[HerdrManager] 🔇 \(agentName) has been silent for \(elapsed)")
            return true
        }

        let content = UNMutableNotificationContent()
        content.title = "🔇 \(agentName) silent"
        content.body = "Silent for \(elapsed) — \(agent.workspaceName)/\(agent.tabName)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "herdr-silent-\(agent.id.raw)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                print("[HerdrManager] Notification post error: \(error)")
            }
        }

        return true
    }

    /// Clear the silent notification key for an agent (e.g., when it's no longer silent).
    func clearSilentNotification(for agentId: AgentID) {
        notifiedKeys.remove("silent:\(agentId.raw)")
    }
}
