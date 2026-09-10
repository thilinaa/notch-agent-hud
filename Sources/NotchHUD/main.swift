import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables: [AnyCancellable] = []
    private var store: SessionStore!
    private var server: HookServer?
    private var codexWatcher: CodexWatcher!
    private var guardian: IdentityGuard!
    private var usageTracker: UsageTracker!
    private var usageAlerts: UsageAlerts!
    private var panelManager: PanelManager!

    /// `notchhud://settings` opens the settings window (used by onboarding
    /// links and for scripting; the pill's gear button does the same).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "notchhud" {
            guard let store else { continue }
            switch url.host {
            case "settings":
                let tab = SettingsWindowController.Tab(rawValue: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                SettingsWindowController.shared.show(configStore: store.configStore, store: store, tab: tab)
            case "setup", "onboarding":
                OnboardingWindowController.shared.show(configStore: store.configStore)
            case "warmup":
                // notchhud://warmup/run says hi to Claude now, as the schedule would.
                if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "run" { WarmupScheduler.shared.runNow() }
            case "alerts":
                // notchhud://alerts/test posts one notification, to check the permission is in place.
                if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "test" { Notifier.deliverTest() }
            case "panel":
                // notchhud://panel/open pins the panel open; /close collapses it. Handy for scripts and screenshots.
                let open = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "close"
                NotificationCenter.default.post(name: .notchHUDPanel, object: nil, userInfo: ["open": open])
            default:
                break
            }
        }
    }

    /// Light/Dark/System from preferences. The notch pill paints itself black
    /// regardless; this governs the panel and the settings windows.
    private func applyAppearance(_ appearance: HUDAppearance) {
        NSApp.appearance = appearance.nsAppearance
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Inspect both appearances without changing the user's system settings.
        if let preview = ProcessInfo.processInfo.environment["NOTCHHUD_PREVIEW_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: preview == "light" ? .aqua : .darkAqua)
        }
        #endif
        let configStore = ConfigStore()
        let config = configStore.config
        let store = SessionStore(configStore: configStore)
        self.store = store
        configStore.adoptDetectedLogins(sessions: store.sessions)
        applyAppearance(config.preferences.appearance)
        configStore.$config
            .map { $0.preferences.appearance }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyAppearance($0) }
            .store(in: &cancellables)

        try? FileManager.default.createDirectory(atPath: Home.directory + "/.notchhud", withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        server = HookServer(port: config.port, onEvent: { obj in
            Task { @MainActor in store.apply(hookEvent: obj) }
        }, onFailure: { message in
            NSLog("NotchHUD: %@", message)
        })
        if server == nil {
            NSLog("NotchHUD: could not create a listener on 127.0.0.1:%d", Int(config.port))
        }

        codexWatcher = CodexWatcher(store: store)
        guardian = IdentityGuard(store: store)
        usageTracker = UsageTracker(store: store)
        usageAlerts = UsageAlerts(usage: usageTracker, configStore: configStore)
        WarmupScheduler.shared.start(usage: usageTracker, configStore: configStore)
        panelManager = PanelManager(store: store, guardian: guardian, usage: usageTracker)

        // First run: walk through setup once the panels are up. The controller
        // keeps the store so "Run setup again" in Settings works later too.
        OnboardingWindowController.shared.register(store: store)
        if configStore.config.needsOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                OnboardingWindowController.shared.show(configStore: configStore)
            }
        }

        // Mirror state into the /state debug endpoint.
        if let box = server?.stateBox {
            store.objectWillChange
                .merge(with: usageTracker.objectWillChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak store, weak usageTracker] _ in
                    guard let store else { return }
                    let items: [[String: Any]] = store.sessions.map {
                        [
                            "id": $0.id, "tool": $0.tool.rawValue, "title": $0.title,
                            "conversationTitle": $0.conversationTitle ?? "",
                            "host": $0.host ?? "",
                            "account": $0.account ?? "",
                            "live": $0.isLive, "ago": $0.isLive ? "" : $0.agoText,
                            "state": $0.state.rawValue, "cwd": $0.cwd,
                            "lane": store.config.laneID(for: $0),
                        ]
                    }
                    func encodeWindow(_ w: WindowUsage?) -> [String: Any] {
                        guard let w else { return [:] }
                        return [
                            "percent": w.percent ?? -1, "tokens": w.tokens ?? -1,
                            "resetsAt": ISO8601DateFormatter().string(from: w.resetsAt),
                            "limitHit": w.limitHit,
                            "splits": w.splits.map { ["label": $0.label, "percent": $0.percent] },
                        ]
                    }
                    let usageLanes: [[String: Any]] = (usageTracker?.subs ?? []).map {
                        ["lane": $0.lane.id, "label": $0.lane.label, "provider": $0.lane.provider.rawValue,
                         "fiveHour": encodeWindow($0.fiveHour), "weekly": encodeWindow($0.weekly)]
                    }
                    let subscriptions: [[String: Any]] = store.config.subscriptions.map {
                        ["id": $0.id, "provider": $0.provider.rawValue, "email": $0.email ?? "",
                         "label": $0.label, "accent": $0.accent.rawValue, "visible": $0.visible]
                    }
                    let payload: [String: Any] = [
                        "sessions": items,
                        "recent_display": store.recent.map { $0.id },
                        "usage": usageLanes,
                        "subscriptions": subscriptions,
                        "guard": [
                            "level": String(describing: store.guardStatus.level),
                            "active": store.guardStatus.activeAccount,
                            "expected": store.guardStatus.expectedAccount ?? "",
                            "text": store.guardStatus.text,
                        ],
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let json = String(data: data, encoding: .utf8) {
                        box.set(json)
                    }
                }
                .store(in: &cancellables)
        }
    }
}

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run() // never returns; keeps `delegate` alive
}

MainActor.assumeIsolated { runApp() }

extension Notification.Name {
    /// userInfo["open"]: Bool — pin the panel open or collapse it.
    static let notchHUDPanel = Notification.Name("io.thilina.notchhud.panel")
}
