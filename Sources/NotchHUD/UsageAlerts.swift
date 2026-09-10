import AppKit
import Foundation
import Combine
import UserNotifications

/// Decides which usage notifications are due. Pure state machine so the
/// rules can be tested without a notification centre: one alert per window
/// when it crosses the threshold, one when it hits the limit, and one when a
/// window that had been running hot resets. A window is identified by its
/// reset time, so a new window starts with a clean slate.
struct UsageAlertPolicy: Codable, Equatable {
    struct WindowState: Codable, Equatable {
        var resetsAt: Date
        var peakPercent: Double = 0
        var notifiedThreshold = false
        var notifiedLimit = false
    }

    enum Kind: Equatable { case threshold(Int), limit, reset }

    struct Alert: Equatable {
        let laneID: String
        let laneLabel: String
        /// "5-hour" or "weekly".
        let window: String
        let kind: Kind
        let resetsAt: Date
    }

    private(set) var windows: [String: WindowState] = [:]

    private static func key(_ laneID: String, _ window: String) -> String { laneID + "|" + window }

    mutating func evaluate(_ subs: [SubscriptionUsage], threshold: Int, now: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        var seen: Set<String> = []
        for sub in subs {
            for (name, window) in [("5-hour", sub.fiveHour), ("weekly", sub.weekly)] {
                let key = Self.key(sub.lane.id, name)
                guard let w = window, w.resetsAt > now else { continue }
                seen.insert(key)
                var state = windows[key] ?? WindowState(resetsAt: w.resetsAt)
                // A different reset time is a new window; the old one, if it ran hot, is worth a word.
                if abs(state.resetsAt.timeIntervalSince(w.resetsAt)) > 60 {
                    if state.resetsAt <= now, state.notifiedThreshold || state.notifiedLimit {
                        alerts.append(Alert(laneID: sub.lane.id, laneLabel: sub.lane.label, window: name, kind: .reset, resetsAt: state.resetsAt))
                    }
                    state = WindowState(resetsAt: w.resetsAt)
                }
                let percent = w.limitHit ? 100 : (w.tightestPercent ?? 0)
                state.peakPercent = max(state.peakPercent, percent)
                if w.limitHit || percent >= 100 {
                    if !state.notifiedLimit {
                        alerts.append(Alert(laneID: sub.lane.id, laneLabel: sub.lane.label, window: name, kind: .limit, resetsAt: w.resetsAt))
                        state.notifiedLimit = true
                        state.notifiedThreshold = true
                    }
                } else if percent >= Double(threshold), !state.notifiedThreshold {
                    alerts.append(Alert(laneID: sub.lane.id, laneLabel: sub.lane.label, window: name, kind: .threshold(Int(percent.rounded())), resetsAt: w.resetsAt))
                    state.notifiedThreshold = true
                }
                windows[key] = state
            }
        }
        // Windows that vanished (expired between refreshes, or the lane went quiet).
        for (key, state) in windows where !seen.contains(key) && state.resetsAt <= now {
            if state.notifiedThreshold || state.notifiedLimit {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let laneID = parts.first ?? key
                let label = subs.first { $0.lane.id == laneID }?.lane.label ?? laneID
                alerts.append(Alert(laneID: laneID, laneLabel: label, window: parts.count > 1 ? parts[1] : "", kind: .reset, resetsAt: state.resetsAt))
            }
            windows.removeValue(forKey: key)
        }
        return alerts
    }
}

/// Delivers usage alerts through Notification Center. Only meaningful inside
/// an app bundle; the bare executable (tests, `swift run`) has no identifier
/// and UNUserNotificationCenter would trap, so everything is a no-op there.
@MainActor
enum Notifier {
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static let delegate = Delegate()

    /// Appends to ~/.notchhud/notifications.log so a "nothing showed up" report
    /// can be diagnosed without a debugger: permission answers, post errors.
    nonisolated static func diag(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let url = URL(fileURLWithPath: Home.directory + "/.notchhud/notifications.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Call once at launch. Without a delegate macOS hides banners while the
    /// app is frontmost, which is exactly when Settings' test button is pressed.
    static func install() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = delegate
        diag("install: bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
        NotificationStatus.shared.refresh()
    }

    static func requestPermission(then completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard available else { return }
        diag("requestAuthorization: asking")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            diag("requestAuthorization: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            Task { @MainActor in
                NotificationStatus.shared.refresh()
                completion(granted)
            }
        }
    }

    static func deliver(title: String, body: String, thread: String, id: String = UUID().uuidString) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            diag("post \"\(title)\": \(error.map { "error: \($0.localizedDescription)" } ?? "accepted")")
        }
    }

    /// Settings → "Send a test". Asks first if macOS has not been asked yet,
    /// so the test lands once the answer is in rather than vanishing.
    static func deliverTest() {
        guard available else { return }
        let post = { deliver(title: "NotchHUD alerts are on",
                             body: "You will hear when a subscription nears its limit, hits it, or gets its window back.",
                             thread: "test") }
        diag("test: checking settings")
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                diag("test: authorization=\(settings.authorizationStatus.rawValue) alerts=\(settings.alertSetting.rawValue)")
                switch settings.authorizationStatus {
                case .notDetermined: requestPermission { granted in if granted { post() } }
                case .denied: NotificationStatus.shared.refresh()
                default: post()
                }
            }
        }
    }

    /// System Settings → Notifications, on this app.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "io.thilina.notchhud"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            Notifier.diag("willPresent \"\(notification.request.content.title)\" while frontmost")
            completionHandler([.banner, .list, .sound])
        }
    }
}

/// Whether macOS lets NotchHUD notify, for the Alerts section in Settings.
@MainActor
final class NotificationStatus: ObservableObject {
    static let shared = NotificationStatus()
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var known = false

    func refresh() {
        guard Notifier.available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                Notifier.diag("status: authorization=\(settings.authorizationStatus.rawValue)")
                self.authorization = settings.authorizationStatus
                self.known = true
            }
        }
    }

    var text: String {
        guard Notifier.available else { return "Available when NotchHUD runs as an app bundle." }
        guard known else { return "Checking…" }
        switch authorization {
        case .authorized: return "Allowed"
        case .provisional: return "Allowed quietly (no banners until you allow them)"
        case .denied: return "Turned off for NotchHUD in System Settings → Notifications"
        case .notDetermined: return "macOS has not asked yet. Send a test to ask."
        @unknown default: return "Unknown"
        }
    }

    var ok: Bool { authorization == .authorized || authorization == .provisional }
}

/// Watches the usage tracker and turns policy decisions into notifications.
@MainActor
final class UsageAlerts {
    private var policy = UsageAlertPolicy()
    private var sink: AnyCancellable?
    private var prefsSink: AnyCancellable?
    private weak var configStore: ConfigStore?
    private var stateURL: URL { URL(fileURLWithPath: Home.directory + "/.notchhud/usage-alerts.json") }

    init(usage: UsageTracker, configStore: ConfigStore) {
        self.configStore = configStore
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(UsageAlertPolicy.self, from: data) {
            policy = saved
        }
        if configStore.config.preferences.usageAlerts { Notifier.requestPermission() }
        prefsSink = configStore.$config.map { $0.preferences.usageAlerts }.removeDuplicates().dropFirst()
            .sink { on in if on { Notifier.requestPermission() } }
        sink = usage.$subs.receive(on: DispatchQueue.main).sink { [weak self] subs in
            self?.evaluate(subs)
        }
    }

    private func evaluate(_ subs: [SubscriptionUsage]) {
        guard let prefs = configStore?.config.preferences else { return }
        let before = policy
        let alerts = policy.evaluate(subs, threshold: prefs.alertThreshold)
        if policy != before, let data = try? JSONEncoder().encode(policy) {
            try? data.write(to: stateURL, options: .atomic)
        }
        guard prefs.usageAlerts else { return }  // still tracked, so turning alerts on later starts clean
        for alert in alerts { deliver(alert) }
    }

    private func deliver(_ alert: UsageAlertPolicy.Alert) {
        let resets = alert.resetsAt.formatted(date: .omitted, time: .shortened)
        let title: String
        let body: String
        switch alert.kind {
        case .threshold(let percent):
            title = "\(alert.laneLabel) · \(alert.window) window at \(percent)%"
            body = "Resets at \(resets)."
        case .limit:
            title = "\(alert.laneLabel) · \(alert.window) limit reached"
            body = "Resets at \(resets)."
        case .reset:
            title = "\(alert.laneLabel) · \(alert.window) window reset"
            body = "Quota is back. Carry on."
        }
        Notifier.deliver(title: title, body: body, thread: alert.laneID,
                         id: "\(alert.laneID)|\(alert.window)|\(alert.kind)|\(Int(alert.resetsAt.timeIntervalSince1970))")
    }
}
