import Foundation
import UserNotifications
import HerdrManagerCore

@MainActor
final class NotificationManager {
    /// Tracks (paneId, seq) pairs we've already notified for, to avoid duplicates.
    private var notifiedKeys: Set<String> = []

    /// User-controlled master switch. When `false`, no authorization is
    /// requested and no notifications are posted. Persisted to a small JSON
    /// file in Application Support so the preference survives relaunches.
    /// Defaults to `false` — the user must opt in explicitly before we
    /// request permission or post anything.
    private(set) var isEnabled: Bool = false

    private let settingsURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("HerdrManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notification-settings.json")
    }()

    init() {
        loadSettings()
    }

    /// Toggle the notification master switch. When turning on, requests
    /// authorization. When turning off, clears the tracked keys so a
    /// re-enable starts fresh.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        saveSettings()
        if enabled {
            requestAuthorization()
        } else {
            notifiedKeys.removeAll()
        }
    }

    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = FileManager.default.contents(atPath: settingsURL.path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = dict["enabled"] as? Bool
        else { return }
        isEnabled = enabled
    }

    private func saveSettings() {
        let dict: [String: Any] = ["enabled": isEnabled]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    /// UNUserNotificationCenter requires a proper app bundle. When running as a
    /// bare SPM executable there is no bundle, so we guard every access.
    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard isEnabled else { return }
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
        guard isEnabled else { return false }
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
        guard isEnabled else { return false }
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
