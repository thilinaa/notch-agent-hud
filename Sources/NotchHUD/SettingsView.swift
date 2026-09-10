import AppKit
import SwiftUI

extension SubscriptionAccent {
    var color: Color {
        switch self {
        case .blue: return Color(light: 0x426AD0, dark: 0x98AFFF)
        case .violet: return Color(light: 0x6E4FC9, dark: 0xB79CFF)
        case .teal: return Color(light: 0x1F7F86, dark: 0x6FD3D8)
        case .green: return Color(light: 0x38755A, dark: 0x8BC5A8)
        case .amber: return Color(light: 0x916013, dark: 0xE6B775)
        case .rose: return Color(light: 0xB3455C, dark: 0xFF9BB0)
        case .graphite: return Color(light: 0x636770, dark: 0x969AA4)
        }
    }

    var displayName: String { rawValue.capitalized }
}

extension HUDAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The settings window. Panels are non-activating, so opening it activates
/// the app explicitly and brings the window to the front.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    enum Tab: String, CaseIterable, Identifiable {
        case general, subscriptions, rules, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .subscriptions: return "Subscriptions"
            case .rules: return "Rules"
            case .advanced: return "Advanced"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .subscriptions: return "person.2"
            case .rules: return "folder.badge.person.crop"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    let selectedTab = TabSelection()

    func show(configStore: ConfigStore, store: SessionStore, tab: Tab? = nil) {
        if window == nil {
            let root = SettingsView(configStore: configStore, store: store, selection: selectedTab)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "NotchHUD Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 600, height: 560))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let tab { selectedTab.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class TabSelection: ObservableObject {
    @Published var tab: SettingsWindowController.Tab = .general
}

enum SettingsStyle {
    static let text = Color(light: 0x202226, dark: 0xEEEEF0)
    static let secondary = Color(light: 0x636770, dark: 0x969AA4)
    static let line = Color(light: 0xDFE1E5, dark: 0x2B2D32)
    static let raised = Color(light: 0xF0F1F2, dark: 0x1D1E21)
    static let amber = Color(light: 0x916013, dark: 0xE6B775)
    static let ok = Color(light: 0x38755A, dark: 0x8BC5A8)
    static let bad = Color(light: 0xB33A2D, dark: 0xFF8A7A)
}

struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var store: SessionStore
    @ObservedObject var selection: TabSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            ForEach(SettingsWindowController.Tab.allCases) { tab in
                pane(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .foregroundStyle(SettingsStyle.text)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsWindowController.Tab) -> some View {
        ScrollView {
            Group {
                switch tab {
                case .general: GeneralPane(configStore: configStore)
                case .subscriptions: SubscriptionsPane(configStore: configStore, store: store)
                case .rules: RulesPane(configStore: configStore, store: store)
                case .advanced: AdvancedPane(configStore: configStore)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Shared pieces

struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.2)
                .foregroundStyle(SettingsStyle.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(SettingsStyle.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsStyle.line))
            if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PaneHeading: View {
    let title: String
    let blurb: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(blurb).font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsDivider: View {
    var body: some View { SettingsStyle.line.frame(height: 1) }
}

/// A labeled row: title and description on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
    }
}

/// Row of preset swatches; the selected one carries a check.
struct AccentSwatches: View {
    let selected: SubscriptionAccent
    var includeGraphite = true
    let onPick: (SubscriptionAccent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SubscriptionAccent.allCases.filter { includeGraphite || $0 != .graphite }, id: \.self) { accent in
                Button { onPick(accent) } label: {
                    Circle().fill(accent.color).frame(width: 18, height: 18)
                        .overlay {
                            if selected == accent {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(accent.displayName)
                .accessibilityLabel(accent.displayName)
                .accessibilityAddTraits(selected == accent ? .isSelected : [])
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject private var warmup = WarmupScheduler.shared
    private var prefs: HUDPreferences { configStore.config.preferences }
    private var schedule: WarmupSchedule { configStore.config.warmup }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeading(title: "General",
                        blurb: "How the pill and panel look and what they show. Everything here applies immediately.")

            SettingsSection(title: "Layout") {
                SettingRow(title: "Density", detail: "Compact tightens spacing and hides secondary lines. Minimal puts each session on one line so long lists fit.") {
                    Picker("", selection: Binding(
                        get: { prefs.density },
                        set: { new in configStore.updatePreferences { $0.density = new } }
                    )) {
                        Text("Cozy").tag(HUDDensity.cozy)
                        Text("Compact").tag(HUDDensity.compact)
                        Text("Minimal").tag(HUDDensity.minimal)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                SettingsDivider()
                SettingRow(title: "Open on hover", detail: "Off: click the pill to open and close the panel. On: it opens when the pointer rests on the pill and closes when it leaves, with a pin to hold it.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.openOnHover },
                        set: { new in configStore.updatePreferences { $0.openOnHover = new } }
                    )).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingRow(title: "Appearance", detail: "The notch pill itself stays black; the panel follows this.") {
                    Picker("", selection: Binding(
                        get: { prefs.appearance },
                        set: { new in configStore.updatePreferences { $0.appearance = new } }
                    )) {
                        Text("System").tag(HUDAppearance.system)
                        Text("Light").tag(HUDAppearance.light)
                        Text("Dark").tag(HUDAppearance.dark)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingRow(title: "Accent", detail: "Colors the working indicator. Amber and red stay reserved for attention and limits.") {
                    AccentSwatches(selected: prefs.accent, includeGraphite: false) { accent in
                        configStore.updatePreferences { $0.accent = accent }
                    }
                }
            }

            SettingsSection(title: "Usage") {
                SettingRow(title: "Show quota as", detail: "Used counts up from zero. Remaining counts down to the reset, and the meter drains with it.") {
                    Picker("", selection: Binding(
                        get: { prefs.usageValue },
                        set: { new in configStore.updatePreferences { $0.usageValue = new } }
                    )) {
                        Text("Used").tag(UsageValueMode.used)
                        Text("Remaining").tag(UsageValueMode.remaining)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                SettingsDivider()
                SettingRow(title: "Meter", detail: "Bars give each window its own line. Rings nest the week inside the 5-hour window with the tightest number in the middle.") {
                    Picker("", selection: Binding(
                        get: { prefs.usageMeter },
                        set: { new in configStore.updatePreferences { $0.usageMeter = new } }
                    )) {
                        Text("Bars").tag(UsageMeterStyle.bars)
                        Text("Rings").tag(UsageMeterStyle.rings)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                SettingsDivider()
                SettingRow(title: "Quota on the pill", detail: "When nothing needs you, the pill's right side shows the subscription closest to a limit instead of \u{201C}All clear\u{201D}. Usage-only mode already shows every lane there.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.pillShowsUsage },
                        set: { new in configStore.updatePreferences { $0.pillShowsUsage = new } }
                    )).toggleStyle(.switch).labelsHidden()
                    .disabled(prefs.usageOnly)
                }
                .opacity(prefs.usageOnly ? 0.5 : 1)
            }

            SettingsSection(title: "Alerts",
                            footnote: "Delivered through Notification Center; macOS asks once to allow them. A window that ran past the threshold also announces when it resets.") {
                SettingRow(title: "Notify when a window nears its limit", detail: "One alert per window when it crosses the threshold, one when the limit is hit.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.usageAlerts },
                        set: { new in configStore.updatePreferences { $0.usageAlerts = new } }
                    )).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingRow(title: "Threshold", detail: "Spent share of a window that counts as nearing the limit.") {
                    Picker("", selection: Binding(
                        get: { prefs.alertThreshold },
                        set: { new in configStore.updatePreferences { $0.alertThreshold = new } }
                    )) {
                        ForEach([50, 70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    .disabled(!prefs.usageAlerts)
                }
                .opacity(prefs.usageAlerts ? 1 : 0.5)
                SettingsDivider()
                SettingRow(title: "Test", detail: Notifier.available ? "Sends one notification now." : "Available when NotchHUD runs as an app bundle.") {
                    Button("Send a test") { Notifier.deliverTest() }.disabled(!Notifier.available)
                }
            }

            SettingsSection(title: "Usage only",
                            footnote: "Sessions keep being tracked in the background, so switching back is instant.") {
                SettingRow(title: "Show only usage and account health",
                           detail: "The pill shows each subscription's tightest window; the panel shows the usage grid and the GitHub guard.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.usageOnly },
                        set: { new in configStore.updatePreferences { $0.usageOnly = new } }
                    )).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingRow(title: "Let sessions that need you break through",
                           detail: "Approval requests and waiting sessions still show on the pill and as cards.") {
                    Toggle("", isOn: Binding(
                        get: { prefs.attentionBreaksThrough },
                        set: { new in configStore.updatePreferences { $0.attentionBreaksThrough = new } }
                    )).toggleStyle(.switch).labelsHidden()
                    .disabled(!prefs.usageOnly)
                }
                .opacity(prefs.usageOnly ? 1 : 0.5)
            }

            SettingsSection(title: "Window warm-up",
                            footnote: "A 5-hour window starts with your first message and ends five hours later, whether that message was \u{201C}hi\u{201D} at 07:00 or real work at 09:00. Saying hi early puts the first reset in the middle of the day instead of the middle of the afternoon. Each run sends one word with `claude -p` from ~/.notchhud/warmup, using the login Claude Code is signed into, and is skipped when a window is already running. A Mac asleep at the scheduled time catches up within two hours.") {
                SettingRow(title: "Start a window on a schedule", detail: "Runs while NotchHUD is open.") {
                    Toggle("", isOn: Binding(
                        get: { schedule.enabled },
                        set: { new in configStore.updateWarmup { $0.enabled = new } }
                    )).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                warmupTimes
                SettingsDivider()
                SettingRow(title: "Weekdays only", detail: "Skip Saturday and Sunday.") {
                    Toggle("", isOn: Binding(
                        get: { schedule.weekdaysOnly },
                        set: { new in configStore.updateWarmup { $0.weekdaysOnly = new } }
                    )).toggleStyle(.switch).labelsHidden()
                }
                SettingsDivider()
                SettingRow(title: "Run now", detail: warmupLastRunText) {
                    HStack(spacing: 8) {
                        if warmup.running { ProgressView().controlSize(.small) }
                        Button("Say hi now") { warmup.runNow() }.disabled(warmup.running)
                    }
                }
            }

            SettingsSection(title: "Setup") {
                SettingRow(title: "Run setup again", detail: "Walks through hooks, subscriptions, rules and permissions.") {
                    Button("Open setup…") {
                        OnboardingWindowController.shared.show(configStore: configStore)
                    }
                }
            }
        }
    }
}

// MARK: General → warm-up pieces

private extension GeneralPane {
    var warmupTimes: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Times").font(.system(size: 13, weight: .medium))
                Text("Local time. One window per time; a second slot only matters if the first window has ended by then.")
                    .font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(schedule.times.enumerated()), id: \.offset) { index, time in
                    HStack(spacing: 6) {
                        DatePicker("", selection: Binding(
                            get: { Self.date(from: time) },
                            set: { new in configStore.updateWarmup { $0.times[index] = Self.string(from: new) } }
                        ), displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field).frame(width: 80)
                        Button {
                            configStore.updateWarmup { $0.times.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(SettingsStyle.secondary)
                        }
                        .buttonStyle(.plain).disabled(schedule.times.count == 1)
                        .help("Remove this time")
                    }
                }
                Button("Add time") {
                    configStore.updateWarmup { w in
                        let next = w.times.compactMap(WarmupScheduler.parseTime).map { $0.0 }.max().map { min(23, $0 + 5) } ?? 7
                        w.times.append(String(format: "%02d:00", next))
                    }
                }
                .disabled(schedule.times.count >= 4)
            }
        }
        .padding(.vertical, 10)
    }

    var warmupLastRunText: String {
        guard let last = warmup.runs.last else { return "No runs yet." }
        let when = last.at.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(when) · \(last.outcome)"
    }

    static func date(from time: String) -> Date {
        let (h, m) = WarmupScheduler.parseTime(time) ?? (7, 0)
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    static func string(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - Subscriptions

struct SubscriptionsPane: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var store: SessionStore
    var showHeading = true
    @State private var newEmail = ""
    @State private var pendingRemoval: Subscription?
    /// Subscription whose accent popover is open.
    @State private var accentPickerFor: String?

    private var detected: [AccountDetection.Detected] {
        AccountDetection.claudeLogins(sessions: store.sessions)
            .filter { configStore.config.subscription(forEmail: $0.email) == nil }
    }

    private var codexEmail: String? { AccountDetection.codexEmail(sessions: store.sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showHeading {
                PaneHeading(title: "Subscriptions",
                            blurb: "Name the logins you own. Labels are yours; NotchHUD never guesses what they mean. Colors mark each lane in the usage strip.")
            }

            SettingsSection(title: "Claude") {
                if configStore.claudeSubscriptions.isEmpty {
                    Text("No Claude account named yet. Pick one below, or add it by email.")
                        .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(configStore.claudeSubscriptions) { sub in
                    subscriptionRow(sub)
                    if sub.id != configStore.claudeSubscriptions.last?.id { SettingsDivider() }
                }
            }

            if configStore.config.hasCodex {
                SettingsSection(title: "Codex") {
                    subscriptionRow(configStore.config.codexSubscription)
                }
            } else {
                SettingsSection(title: "Codex") {
                    Text("Codex has not been detected on this Mac. It appears here once it signs in or runs a session.")
                        .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                }
            }

            if !detected.isEmpty {
                SettingsSection(title: "Seen on this Mac, not named yet") {
                    ForEach(detected) { d in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundStyle(SettingsStyle.amber)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.email).font(.system(size: 12, weight: .medium))
                                Text(detectedNote(d)).font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                            }
                            Spacer()
                            Button("Name it") { configStore.addClaudeAccount(email: d.email) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 6)
                        if d.id != detected.last?.id { SettingsDivider() }
                    }
                }
            }

            SettingsSection(title: "Add an account by email",
                            footnote: "Use this for a login the HUD has not seen yet. The email must match what Claude Code reports.") {
                HStack(spacing: 8) {
                    TextField("name@example.com", text: $newEmail)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTyped)
                    Button("Add", action: addTyped)
                        .disabled(!isValidEmail(newEmail))
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            configStore.adoptDetectedLogins(sessions: store.sessions)
            adoptCodexEmail()
        }
        .onChange(of: codexEmail) { _, _ in adoptCodexEmail() }
        .confirmationDialog(
            "Remove \(pendingRemoval?.label ?? "this subscription")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { sub in
            Button("Remove", role: .destructive) { configStore.remove(sub.id) }
            Button("Cancel", role: .cancel) {}
        } message: { sub in
            Text("Sessions from \(sub.email ?? "this login") show up as an unlabeled lane. Repository rules keep their GitHub account but forget this subscription.")
        }
    }

    // MARK: Rows

    private func subscriptionRow(_ sub: Subscription) -> some View {
        HStack(spacing: 12) {
            accentMenu(sub)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Label", text: Binding(
                    get: { sub.label },
                    set: { new in configStore.update(sub.id) { $0.label = new } }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                Text(emailLine(sub)).font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if sub.provider == .claude, AccountDetection.activeClaudeEmail() == sub.email {
                Text("Active").font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SettingsStyle.line))
                    .foregroundStyle(SettingsStyle.secondary)
                    .help("The login Claude Code is using right now")
            }
            Toggle("", isOn: Binding(
                get: { sub.visible },
                set: { new in configStore.update(sub.id) { $0.visible = new } }
            ))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
            .help(sub.visible ? "Shown in the usage strip and recents" : "Hidden; still tracked")
            if sub.provider == .claude {
                Button { pendingRemoval = sub } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(SettingsStyle.secondary)
                .help("Remove this subscription")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .padding(.vertical, 8)
        .opacity(sub.visible ? 1 : 0.6)
    }

    private func accentMenu(_ sub: Subscription) -> some View {
        Button { accentPickerFor = sub.id } label: {
            Circle().fill(sub.accent.color).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lane color")
        .accessibilityLabel("Lane color: \(sub.accent.displayName)")
        .popover(isPresented: Binding(
            get: { accentPickerFor == sub.id },
            set: { if !$0 { accentPickerFor = nil } }
        ), arrowEdge: .leading) {
            AccentSwatches(selected: sub.accent) { accent in
                configStore.update(sub.id) { $0.accent = accent }
                accentPickerFor = nil
            }
            .padding(12)
        }
    }

    private func emailLine(_ sub: Subscription) -> String {
        if let email = sub.email, !email.isEmpty { return email }
        return sub.provider == .codex ? "Login not detected yet" : "No email"
    }

    private func detectedNote(_ d: AccountDetection.Detected) -> String {
        var parts: [String] = []
        if d.active { parts.append("Active Claude Code login") }
        if d.sessions > 0 { parts.append("\(d.sessions) session\(d.sessions == 1 ? "" : "s")") }
        return parts.isEmpty ? "Seen once" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func addTyped() {
        guard isValidEmail(newEmail) else { return }
        configStore.addClaudeAccount(email: newEmail)
        newEmail = ""
    }

    private func isValidEmail(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        return t[t.index(after: at)...].contains(".") && !t.hasSuffix(".")
    }

    /// Codex's email is detected, never typed: adopt it once we know it.
    private func adoptCodexEmail() {
        guard let email = codexEmail, configStore.config.hasCodex else { return }
        let codex = configStore.config.codexSubscription
        if codex.email != email { configStore.update(codex.id) { $0.email = email } }
    }
}

// MARK: - Rules

struct RulesPane: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var store: SessionStore
    var showHeading = true
    @State private var ghAccounts: [String] = []
    @State private var newOwner = ""

    private var rules: [RepoRule] { configStore.config.rules }
    private var pathRules: [RepoRule] { rules.filter { $0.kind == .pathPrefix }.sorted { $0.value < $1.value } }
    private var ownerRules: [RepoRule] { rules.filter { $0.kind == .owner }.sorted { $0.value < $1.value } }
    private var suggestions: [String] {
        Array(RuleSuggestions.pathPrefixes(sessions: store.sessions, rules: rules).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showHeading {
                PaneHeading(title: "Repository rules",
                            blurb: "Where each subscription and GitHub account is expected. Owner rules beat folder rules; among folders the longest match wins. Both fields are optional.")
            }

            SettingsSection(title: "Folders",
                            footnote: "A session inside the folder whose login differs from the expected subscription gets an amber account label. The GitHub account feeds the identity guard.") {
                if pathRules.isEmpty {
                    Text("No folder rules yet.").font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(pathRules) { rule in
                    ruleRow(rule)
                    SettingsDivider()
                }
                HStack(spacing: 8) {
                    Button("Choose folder…", action: chooseFolder)
                    if !suggestions.isEmpty {
                        Text("Suggested:").font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                        ForEach(suggestions, id: \.self) { prefix in
                            Button(prefix) { configStore.addRule(kind: .pathPrefix, value: prefix) }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            SettingsSection(title: "GitHub owners",
                            footnote: "Matched against the repository's origin remote (github.com/<owner>/…), so a checkout anywhere on disk follows its org.") {
                if ownerRules.isEmpty {
                    Text("No owner rules yet.").font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(ownerRules) { rule in
                    ruleRow(rule)
                    SettingsDivider()
                }
                HStack(spacing: 8) {
                    TextField("org-or-user", text: $newOwner)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        .onSubmit(addOwner)
                    Button("Add owner", action: addOwner)
                        .disabled(newOwner.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear { ghAccounts = IdentityGuard.savedGhAccounts() }
    }

    private func ruleRow(_ rule: RepoRule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: rule.kind == .pathPrefix ? "folder" : "building.2")
                .foregroundStyle(SettingsStyle.secondary).frame(width: 16)
            Text(rule.value).font(.system(size: 12, weight: .medium, design: rule.kind == .pathPrefix ? .monospaced : .default))
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 8)
            subscriptionPicker(rule)
            ghPicker(rule)
            Button { configStore.removeRule(rule.id) } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(SettingsStyle.secondary)
            .help("Remove rule")
        }
        .padding(.vertical, 8)
    }

    private func subscriptionPicker(_ rule: RepoRule) -> some View {
        Picker("", selection: Binding(
            get: { rule.subscriptionID ?? "" },
            set: { new in configStore.updateRule(rule.id) { $0.subscriptionID = new.isEmpty ? nil : new } }
        )) {
            Text("Any subscription").tag("")
            ForEach(configStore.claudeSubscriptions) { sub in
                Text(sub.label).tag(sub.id)
            }
        }
        .labelsHidden().frame(width: 150)
        .help("Expected subscription")
    }

    private func ghPicker(_ rule: RepoRule) -> some View {
        let options = Array(Set(ghAccounts + [rule.ghAccount].compactMap { $0 })).sorted()
        return Picker("", selection: Binding(
            get: { rule.ghAccount ?? "" },
            set: { new in configStore.updateRule(rule.id) { $0.ghAccount = new.isEmpty ? nil : new } }
        )) {
            Text("Any gh account").tag("")
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().frame(width: 150)
        .help("Expected GitHub CLI account")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.directoryURL = URL(fileURLWithPath: Home.directory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = Home.directory
        var path = url.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        if !rules.contains(where: { $0.kind == .pathPrefix && $0.value == path }) {
            configStore.addRule(kind: .pathPrefix, value: path)
        }
    }

    private func addOwner() {
        let owner = newOwner.trimmingCharacters(in: .whitespaces).lowercased()
        guard !owner.isEmpty else { return }
        if !rules.contains(where: { $0.kind == .owner && $0.value == owner }) {
            configStore.addRule(kind: .owner, value: owner)
        }
        newOwner = ""
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @ObservedObject var configStore: ConfigStore
    var showHeading = true
    @State private var portText = ""
    @State private var hookStatus: HookInstaller.Status = .notInstalled
    @State private var hookMessage: String?
    @State private var accessibilityGranted = false
    @State private var permissionTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showHeading {
                PaneHeading(title: "Advanced", blurb: "Integration details. Most people never need to change these.")
            }

            SettingsSection(title: "Claude Code hooks",
                            footnote: "Adds NotchHUD's relay to SessionStart, UserPromptSubmit, Notification, Stop and SessionEnd in ~/.claude/settings.json. A timestamped backup of the file is kept. Running sessions pick the hooks up on restart.") {
                SettingRow(title: hookTitle, detail: hookDetail) {
                    HStack(spacing: 8) {
                        statusDot(hookStatus == .installed)
                        Button(hookStatus == .installed ? "Reinstall" : "Install hooks", action: installHooks)
                    }
                }
                if let hookMessage {
                    Text(hookMessage).font(.system(size: 11)).foregroundStyle(SettingsStyle.secondary)
                        .padding(.bottom, 8)
                }
            }

            SettingsSection(title: "Accessibility",
                            footnote: "Needed to switch to the exact terminal tab when you click a session. Without it, clicking still brings the app forward.") {
                SettingRow(title: accessibilityGranted ? "Granted" : "Not granted",
                           detail: "System Settings → Privacy & Security → Accessibility → NotchHUD") {
                    HStack(spacing: 8) {
                        statusDot(accessibilityGranted)
                        if !accessibilityGranted {
                            Button("Request…") { AccessibilityPermission.prompt() }
                        }
                        Button("Open System Settings") { AccessibilityPermission.openSystemSettings() }
                    }
                }
            }

            SettingsSection(title: "Usage data",
                            footnote: "On: the active Claude login's OAuth token is read from the Keychain (the item Claude Code maintains) and sent only to api.anthropic.com, so the usage strip shows exact percentages. macOS may ask once to allow NotchHUD access; choose Always Allow. Off: estimates from transcripts only, and the Keychain is never touched.") {
                SettingRow(title: "Exact usage from Anthropic's API", detail: "Same numbers as /usage inside Claude Code.") {
                    Toggle("", isOn: Binding(
                        get: { configStore.config.preferences.useUsageAPI },
                        set: { new in configStore.updatePreferences { $0.useUsageAPI = new } }
                    )).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsSection(title: "Apps") {
                SettingRow(title: "Default terminal", detail: "Used when a session's host app could not be detected.") {
                    TextField("Terminal", text: Binding(
                        get: { configStore.config.terminalApp },
                        set: { configStore.config.terminalApp = $0 }
                    )).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                SettingsDivider()
                SettingRow(title: "Codex desktop app", detail: "Bundle identifier of the app to activate for desktop Codex sessions.") {
                    TextField("com.openai.codex", text: Binding(
                        get: { configStore.config.codexApp },
                        set: { configStore.config.codexApp = $0.isEmpty ? HUDConfig().codexApp : $0 }
                    )).textFieldStyle(.roundedBorder).frame(width: 180)
                }
            }

            SettingsSection(title: "Relay port",
                            footnote: "Changing the port takes effect after relaunching NotchHUD, and the hooks must be reinstalled so the relay posts to the new port.") {
                SettingRow(title: "Local port", detail: "Hooks post to http://127.0.0.1:<port>/event.") {
                    TextField("48618", text: $portText)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitPort)
                }
            }
        }
        .onAppear {
            portText = String(configStore.config.port)
            refreshStatus()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in accessibilityGranted = AccessibilityPermission.granted }
            }
        }
        .onDisappear { permissionTimer?.invalidate(); commitPort() }
    }

    private var hookTitle: String {
        switch hookStatus {
        case .installed: return "Installed"
        case .partial(let missing): return "Partially installed"
            + (missing.isEmpty ? "" : " (missing \(missing.joined(separator: ", ")))")
        case .notInstalled: return "Not installed"
        case .settingsUnreadable: return "settings.json is not valid JSON"
        }
    }

    private var hookDetail: String {
        hookStatus == .installed ? "Claude Code sessions report to the HUD." : "Sessions will not appear until the hooks are installed."
    }

    private func statusDot(_ ok: Bool) -> some View {
        Circle().fill(ok ? SettingsStyle.ok : SettingsStyle.bad).frame(width: 8, height: 8)
    }

    private func refreshStatus() {
        hookStatus = HookInstaller.status()
        accessibilityGranted = AccessibilityPermission.granted
    }

    private func installHooks() {
        do {
            try HookInstaller.install(port: configStore.config.port)
            hookMessage = "Hooks installed. New Claude Code sessions will report to NotchHUD."
        } catch {
            hookMessage = error.localizedDescription
        }
        refreshStatus()
    }

    private func commitPort() {
        guard let p = UInt16(portText.trimmingCharacters(in: .whitespaces)), p > 0 else {
            portText = String(configStore.config.port)
            return
        }
        if p != configStore.config.port { configStore.config.port = p }
    }
}
