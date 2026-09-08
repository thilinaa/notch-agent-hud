import AppKit
import SwiftUI

/// First-run setup. Reuses the settings panes so there is one implementation
/// of each form; the flow only adds ordering, explanation and a finish line.
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    /// Set once at launch so "Run setup again" from Settings has a store too.
    private weak var sessionStore: SessionStore?

    func register(store: SessionStore) { sessionStore = store }

    func show(configStore: ConfigStore) {
        guard let sessionStore else { return }
        if window == nil {
            let root = OnboardingView(configStore: configStore, store: sessionStore) { [weak self] in
                self?.window?.close()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Set up NotchHUD"
            w.styleMask = [.titled, .closable]
            w.setContentSize(NSSize(width: 640, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var store: SessionStore
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, hooks, subscriptions, rules, permissions, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .hooks: return "Hooks"
            case .subscriptions: return "Subscriptions"
            case .rules: return "Rules"
            case .permissions: return "Permissions"
            case .done: return "Done"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var hookStatus: HookInstaller.Status = .notInstalled
    @State private var hookMessage: String?
    @State private var accessibilityGranted = false
    @State private var permissionTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            stepper.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollView {
                content.padding(.horizontal, 28).padding(.vertical, 12)
            }
            footer.padding(.horizontal, 28).padding(.vertical, 18)
                .overlay(alignment: .top) { SettingsStyle.line.frame(height: 1) }
        }
        .frame(minWidth: 600, minHeight: 540)
        .foregroundStyle(SettingsStyle.text)
        .onAppear {
            refresh()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in accessibilityGranted = AccessibilityPermission.granted }
            }
        }
        .onDisappear { permissionTimer?.invalidate() }
    }

    // MARK: Chrome

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? configStore.config.preferences.accent.color : SettingsStyle.line)
                        .frame(width: 7, height: 7)
                    Text(s.title).font(.system(size: 11, weight: s == step ? .semibold : .regular))
                        .foregroundStyle(s == step ? SettingsStyle.text : SettingsStyle.secondary)
                }
                if s != Step.allCases.last {
                    Rectangle().fill(SettingsStyle.line).frame(height: 1).frame(maxWidth: 28)
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }
            }
            Spacer()
            if step == .rules {
                Button("Skip for now") { go(1) }
            }
            Button(primaryTitle, action: primary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .done: return "Finish"
        default: return "Continue"
        }
    }

    private func primary() {
        if step == .done {
            configStore.updatePreferences { $0.onboardingCompleted = true }
            configStore.saveNow()
            onFinish()
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
        refresh()
    }

    private func refresh() {
        hookStatus = HookInstaller.status()
        accessibilityGranted = AccessibilityPermission.granted
        configStore.adoptDetectedLogins(sessions: store.sessions)
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .hooks: hooks
        case .subscriptions:
            VStack(alignment: .leading, spacing: 18) {
                heading("Name your subscriptions",
                        "The login Claude Code is using right now is already here. Give it a name you recognise, then add any other accounts you switch between. Codex appears once it has been detected. Using Codex only? Just continue.")
                SubscriptionsPane(configStore: configStore, store: store, showHeading: false)
            }
        case .rules:
            VStack(alignment: .leading, spacing: 18) {
                heading("Where does each account belong?",
                        "Optional. Map folders or GitHub owners to a subscription and a gh account, and the HUD warns when a session is using the wrong one. You can do this later in Settings.")
                RulesPane(configStore: configStore, store: store, showHeading: false)
            }
        case .permissions: permissions
        case .done: done
        }
    }

    private func heading(_ title: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(blurb).font(.system(size: 13)).foregroundStyle(SettingsStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                NotchHUDLogo().foregroundStyle(configStore.config.preferences.accent.color).scaleEffect(1.6)
                Text("NotchHUD").font(.system(size: 26, weight: .semibold))
            }
            heading("Your agents, at the top of the screen",
                    "A small pill around the notch shows which Claude Code and Codex sessions are working, which need you, and how much of each subscription's quota is left. Click a session to jump to its terminal tab.")
            VStack(alignment: .leading, spacing: 12) {
                bullet("terminal", "Hooks tell the HUD when a session starts, waits, or finishes.")
                bullet("person.2", "Subscriptions are named by you. Two personal accounts are fine.")
                bullet("folder.badge.person.crop", "Optional rules warn when a repo is using the wrong account.")
                bullet("hand.raised", "Accessibility lets a click land on the exact terminal tab.")
            }
            Text("Setup takes about a minute. Everything can be changed later from the gear icon in the panel.")
                .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(SettingsStyle.secondary)
            Text(text).font(.system(size: 13))
        }
    }

    private var hooks: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Connect Claude Code",
                    "Claude Code runs a small relay script on session events. NotchHUD adds it to five hooks in ~/.claude/settings.json and keeps a timestamped backup of the file. Nothing else in the file is touched.")
            SettingsSection(title: "Status") {
                HStack(spacing: 10) {
                    Circle().fill(hookStatus == .installed ? SettingsStyle.ok : SettingsStyle.bad).frame(width: 8, height: 8)
                    Text(hookStatusText).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(hookStatus == .installed ? "Reinstall" : "Install hooks") {
                        do {
                            try HookInstaller.install(port: configStore.config.port)
                            hookMessage = "Done. New Claude Code sessions will show up in the HUD."
                        } catch {
                            hookMessage = error.localizedDescription
                        }
                        hookStatus = HookInstaller.status()
                    }
                }
                .padding(.vertical, 10)
                if let hookMessage {
                    Text(hookMessage).font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary).padding(.bottom, 8)
                }
            }
            Text("Sessions already running pick the hooks up when they restart. Cloud sessions cannot reach this Mac and will not appear.")
                .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hookStatusText: String {
        switch hookStatus {
        case .installed: return "Hooks installed"
        case .partial: return "Some hooks missing"
        case .notInstalled: return "Hooks not installed"
        case .settingsUnreadable: return "~/.claude/settings.json is not valid JSON"
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Let clicks reach the right tab",
                    "Focusing the exact terminal tab uses the Accessibility API. macOS asks you to allow NotchHUD once. Without it, clicking a session still brings its app forward.")
            SettingsSection(title: "Accessibility") {
                HStack(spacing: 10) {
                    Circle().fill(accessibilityGranted ? SettingsStyle.ok : SettingsStyle.bad).frame(width: 8, height: 8)
                    Text(accessibilityGranted ? "Granted" : "Not granted yet").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if !accessibilityGranted {
                        Button("Request…") { AccessibilityPermission.prompt() }
                    }
                    Button("Open System Settings") { AccessibilityPermission.openSystemSettings() }
                }
                .padding(.vertical, 10)
            }
            Text("This screen updates by itself once the switch is on. It is fine to continue without it.")
                .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("You're set",
                    "The pill sits at the top of every screen: flush around the notch on the MacBook display, a small capsule under the menu bar elsewhere. Hover to expand it, click to pin it open.")
            SettingsSection(title: "Summary") {
                summaryRow("Hooks", hookStatus == .installed ? "installed" : "not installed", ok: hookStatus == .installed)
                SettingsDivider()
                summaryRow("Subscriptions", configStore.claudeSubscriptions.map { $0.label }.joined(separator: ", ")
                           + (configStore.config.hasCodex ? " + Codex" : ""), ok: !configStore.claudeSubscriptions.isEmpty)
                SettingsDivider()
                summaryRow("Rules", configStore.config.rules.isEmpty ? "none" : "\(configStore.config.rules.count) configured", ok: true)
                SettingsDivider()
                summaryRow("Accessibility", accessibilityGranted ? "granted" : "not granted", ok: accessibilityGranted)
            }
            Text("Change any of this from the gear icon in the panel footer.")
                .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
        }
    }

    private func summaryRow(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(ok ? SettingsStyle.ok : SettingsStyle.secondary).frame(width: 7, height: 7)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.vertical, 9)
    }
}
