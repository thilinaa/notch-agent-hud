import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }

}

private enum Palette {
    static let done = Color(light: 0x38755A, dark: 0x8BC5A8)
    static let mismatch = Color(light: 0xB33A2D, dark: 0xFF8A7A)
    static let okGreen = Color(light: 0x38755A, dark: 0x8BC5A8)
}

/// App icons for the tool badge, loaded from the installed apps.
@MainActor
enum ToolIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(bundleId: String) -> NSImage? {
        if let cached = cache[bundleId] { return cached }
        var img: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 36, height: 36)
            img = icon
        }
        cache[bundleId] = img
        return img
    }
}

/// Shared graphite surfaces; status color is reserved for activity and exceptions.
private enum HUDStyle {
    static let background = Color(light: 0xFAFAFA, dark: 0x151618)
    static let raised = Color(light: 0xF0F1F2, dark: 0x1D1E21)
    static let text = Color(light: 0x202226, dark: 0xEEEEF0)
    static let secondary = Color(light: 0x636770, dark: 0x969AA4)
    static let line = Color(light: 0xDFE1E5, dark: 0x2B2D32)
    static let accent = Color(light: 0x426AD0, dark: 0x98AFFF)
    static let amber = Color(light: 0x916013, dark: 0xE6B775)
}

private struct HUDMeasurementsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func measureHUDHeight(_ key: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: HUDMeasurementsKey.self, value: [key: geo.size.height])
        })
    }
}

private extension SubscriptionAccent {
    /// The dark-mode shade, for the always-black notch pill.
    var onBlack: Color {
        switch self {
        case .blue: return Color(hex: 0x98AFFF)
        case .violet: return Color(hex: 0xB79CFF)
        case .teal: return Color(hex: 0x6FD3D8)
        case .green: return Color(hex: 0x8BC5A8)
        case .amber: return Color(hex: 0xE6B775)
        case .rose: return Color(hex: 0xFF9BB0)
        case .graphite: return Color(hex: 0x969AA4)
        }
    }
}

/// Live indicator for working sessions: a breathing core plus an expanding
/// ping ring (matches the prototype's `hudpulse`). Runs as Core Animation
/// layer animations on the render server, so the always-on pill costs no
/// per-frame view updates. Static under Reduce Motion.
private struct WorkingDot: View {
    var color: Color
    var size: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulseDotRepresentable(color: NSColor(color), animated: !reduceMotion)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct PulseDotRepresentable: NSViewRepresentable {
    let color: NSColor
    let animated: Bool
    func makeNSView(context: Context) -> PulseDotView { PulseDotView(frame: .zero) }
    func updateNSView(_ view: PulseDotView, context: Context) {
        view.color = color
        view.animated = animated
    }
}

private final class PulseDotView: NSView {
    var color: NSColor = .controlAccentColor { didSet { applyColors() } }
    var animated = true { didSet { syncAnimations() } }
    private let core = CALayer()
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.borderWidth = 1
        layer?.addSublayer(ring)
        layer?.addSublayer(core)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Let clicks fall through to the SwiftUI button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in [core, ring] {
            sub.frame = bounds
            sub.cornerRadius = bounds.width / 2
        }
        CATransaction.commit()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimations()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            core.backgroundColor = color.cgColor
            ring.borderColor = color.cgColor
            CATransaction.commit()
        }
    }

    private func syncAnimations() {
        core.removeAllAnimations()
        ring.removeAllAnimations()
        guard window != nil, animated else {
            ring.opacity = 0
            core.opacity = 1
            return
        }
        // Breath: core shrinks and dims, then recovers (1.4s round trip).
        let breathScale = CABasicAnimation(keyPath: "transform.scale")
        breathScale.fromValue = 1; breathScale.toValue = 0.78
        let breathFade = CABasicAnimation(keyPath: "opacity")
        breathFade.fromValue = 1; breathFade.toValue = 0.45
        let breath = CAAnimationGroup()
        breath.animations = [breathScale, breathFade]
        breath.duration = 0.7
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        core.add(breath, forKey: "breath")

        // Ping: ring travels outward and fades; restarts invisibly at zero opacity.
        ring.opacity = 0
        let pingScale = CABasicAnimation(keyPath: "transform.scale")
        pingScale.fromValue = 1; pingScale.toValue = 3.2
        let pingFade = CABasicAnimation(keyPath: "opacity")
        pingFade.fromValue = 0.65; pingFade.toValue = 0
        let ping = CAAnimationGroup()
        ping.animations = [pingScale, pingFade]
        ping.duration = 1.6
        ping.repeatCount = .infinity
        ping.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(ping, forKey: "ping")
    }
}

/// Cascades panel content in when the panel opens: each item fades and drops
/// into place slightly after the previous one.
private struct HUDRevealedKey: EnvironmentKey { static let defaultValue = true }
private extension EnvironmentValues {
    var hudRevealed: Bool {
        get { self[HUDRevealedKey.self] }
        set { self[HUDRevealedKey.self] = newValue }
    }
}

private struct StaggerReveal: ViewModifier {
    let index: Int
    @Environment(\.hudRevealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(revealed || reduceMotion ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : -10)
            .animation(reduceMotion ? nil
                       : .spring(response: 0.38, dampingFraction: 0.86).delay(0.05 + Double(min(index, 9)) * 0.045),
                       value: revealed)
    }
}

struct HUDView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageTracker
    let hasNotch: Bool
    let notchWidth: CGFloat
    let collapsedWidth: CGFloat
    let expandedWidth: CGFloat
    let pillHeight: CGFloat
    let maxBodyHeight: CGFloat
    let onFocusSession: (AgentSession) -> Void
    let onSwitchAccount: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var expanded = false
    @State private var pinned = false
    @State private var inside = false
    @State private var showRecent = false
    @State private var hoveredRow: String?
    @State private var measurements: [String: CGFloat] = [:]
    @State private var collapseTask: Task<Void, Never>?
    /// Drives the staggered content cascade; reset on collapse so it replays.
    @State private var revealed = false

    private var prefs: HUDPreferences { store.config.preferences }
    /// Compact and minimal both tighten spacing; minimal also flattens rows to one line.
    private var compact: Bool { prefs.density != .cozy }
    private var minimal: Bool { prefs.density == .minimal }
    private var usageOnly: Bool { prefs.usageOnly }
    /// Attention still surfaces in usage-only mode unless silenced.
    private var showsAttention: Bool { !usageOnly || prefs.attentionBreaksThrough }
    private var accentColor: Color { prefs.accent.color }
    private var usageValueMode: UsageValueMode { prefs.usageValue }

    /// Jump to the session's terminal and get the panel out of the way.
    private func focus(_ s: AgentSession) {
        collapseTask?.cancel()
        pinned = false
        expanded = false
        onFocusSession(s)
    }
    private var pillAccent: Color { hasNotch ? prefs.accent.onBlack : prefs.accent.color }

    /// Collapsed-pill summary for usage-only mode: each visible lane's tightest
    /// window. Shown as a lane-colored dot plus the value, since the pill has no
    /// room for labels around the notch; the label lives in the tooltip and panel.
    private struct PillUsage: Identifiable {
        let id: String
        let label: String
        let accent: Color
        let value: String
        let hot: Bool
    }

    private var pillUsage: [PillUsage] {
        usage.subs.prefix(3).compactMap { sub in
            let windows = [sub.fiveHour, sub.weekly].compactMap { $0 }.filter { $0.resetsAt > Date() }
            guard let tightest = windows.max(by: { ($0.tightestPercent ?? -1) < ($1.tightestPercent ?? -1) }) else { return nil }
            let value = tightest.limitHit ? "limit" : tightest.tightestValueText(usageValueMode)
            return PillUsage(id: sub.id, label: sub.lane.label,
                             accent: hasNotch ? sub.lane.accent.onBlack : sub.lane.accent.color,
                             value: value, hot: tightest.limitHit || (tightest.tightestPercent ?? 0) > 60)
        }
    }

    private var usageSummary: String {
        let parts = pillUsage.map { "\($0.label) \($0.value)" }
        return parts.isEmpty ? "No usage data" : parts.joined(separator: " · ")
    }

    private var attention: [AgentSession] {
        store.active.filter { $0.state == .permission || $0.state == .needsInput }
            .sorted {
                if $0.state != $1.state { return $0.state == .permission }
                return $0.lastEvent > $1.lastEvent
            }
    }
    private var working: [AgentSession] { store.active.filter { $0.state == .working } }
    private var completed: [AgentSession] { store.active.filter { $0.state == .done } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                // Plain fade: the frame spring supplies the unfurl and the
                // stagger cascade the motion. A `.move` transition here could
                // get stuck partway when a hover was interrupted mid-animation,
                // leaving the body parked over the pill.
                panelBody
                    .transition(.opacity)
            }
        }
        .frame(width: expanded ? expandedWidth : collapsedWidth)
        .background { panelSurface }
        .clipShape(shape)
        .overlay(shape.strokeBorder(hasNotch ? .clear : HUDStyle.line, lineWidth: 1))
        // Soft ambient shadow. The window keeps a wide transparent margin so
        // the blur fades to nothing before the window edge cuts it off.
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.22), radius: 22, y: 12)
        .onHover { value in
            inside = value
            // Click-to-open by default; hovering only matters when the user asked for it.
            guard prefs.openOnHover else { return }
            collapseTask?.cancel()
            if value { expanded = true }
            else { scheduleCollapse() }
        }
        .onDisappear { collapseTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .notchHUDPanel)) { note in
            let open = (note.userInfo?["open"] as? Bool) ?? true
            collapseTask?.cancel()
            pinned = open
            expanded = open
        }
        .onChange(of: expanded) { _, open in revealed = open }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: expanded)
    }

    @ViewBuilder
    private var panelSurface: some View {
        if !expanded || reduceTransparency {
            shape.fill(HUDStyle.background)
        } else if #available(macOS 26.0, *) {
            // Regular glass supplies native backdrop diffusion and edge lighting.
            // Neutral tint plus a readability scrim keeps the large reading surface calm.
            Color.clear
                .glassEffect(.regular.tint(HUDStyle.background.opacity(0.50)), in: shape)
                .overlay { shape.fill(HUDStyle.background.opacity(colorScheme == .dark ? 0.52 : 0.36)) }
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(HUDStyle.background.opacity(0.72)) }
        }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: hasNotch ? 0 : 15,
            bottomLeadingRadius: expanded ? 22 : 15,
            bottomTrailingRadius: expanded ? 22 : 15,
            topTrailingRadius: hasNotch ? 0 : 15
        )
    }

    private func scheduleCollapse() {
        guard !pinned, !inside else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled { expanded = false }
        }
    }

    private var header: some View {
        Button {
            collapseTask?.cancel()
            if expanded { expanded = false; pinned = false }
            else { expanded = true; pinned = true }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    if usageOnly {
                        if pillUsage.isEmpty {
                            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 10))
                                .foregroundStyle(hasNotch ? Color(hex: 0x969AA4) : HUDStyle.secondary)
                            Text("No usage data").lineLimit(1)
                        }
                        ForEach(pillUsage) { item in
                            HStack(spacing: 4) {
                                Circle().fill(item.accent).frame(width: 6, height: 6)
                                Text(item.value).monospacedDigit().lineLimit(1)
                                    .foregroundStyle(item.hot ? (hasNotch ? Color(hex: 0xE6B775) : HUDStyle.amber)
                                                     : (hasNotch ? Color(hex: 0xEEEEF0) : HUDStyle.text))
                            }
                            .help(item.label)
                        }
                    } else {
                        if working.isEmpty {
                            Circle().fill(HUDStyle.secondary).frame(width: 6, height: 6)
                        } else {
                            WorkingDot(color: pillAccent)
                        }
                        Text(working.isEmpty ? (store.active.isEmpty ? "All quiet" : "\(store.active.count) active") : "\(working.count) working")
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep the physical camera area clear in BOTH panel states.
                if hasNotch { Color.clear.frame(width: notchWidth + 16) }
                HStack(spacing: 6) {
                    if store.guardStatus.level == .mismatch {
                        Image(systemName: "exclamationmark.shield")
                        Text("gh default")
                    } else if showsAttention, !attention.isEmpty {
                        Text("\(attention.count) needs you")
                    } else {
                        Text(usageOnly ? "Usage" : "All clear")
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(store.guardStatus.level == .mismatch ? (hasNotch ? Color(hex: 0xFF8A7A) : Palette.mismatch) : (attention.isEmpty || !showsAttention) ? (hasNotch ? Color(hex: 0x969AA4) : HUDStyle.secondary) : (hasNotch ? Color(hex: 0xE6B775) : HUDStyle.amber))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hasNotch ? Color(hex: 0xEEEEF0) : HUDStyle.text)
            .padding(.horizontal, 16)
            .frame(height: pillHeight)
            .background(hasNotch ? Color.black : HUDStyle.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(usageOnly ? "\(usageSummary). \(expanded ? "Collapse" : "Expand") usage panel"
                            : "\(working.count) working, \(attention.count) need you. \(expanded ? "Collapse" : "Expand") agent panel")
    }

    private var activityBudget: CGFloat {
        HUDLayout.activityHeight(maxBodyHeight: maxBodyHeight,
                                 heading: measurements["heading"] ?? 78,
                                 footer: measurements["footer"] ?? 265)
    }

    private var attentionViewport: CGFloat {
        let firstThree = attention.prefix(3).map { measurements["card-" + $0.id] ?? 150 }
        let others = !working.isEmpty || !completed.isEmpty || !store.recent.isEmpty
        return HUDLayout.attentionHeight(firstThree: firstThree, activityBudget: activityBudget,
                                         hasOtherSessions: others)
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            panelHeading.measureHUDHeight("heading").stagger(0)
            // Usage and account health are outside this scrolling region.
            if usageOnly {
                // Only sessions that need you get through, as cards; the rest is hidden.
                if showsAttention, !attention.isEmpty {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            sectionLabel("Needs you", count: attention.count, tint: HUDStyle.amber).stagger(1)
                            attentionCards
                        }
                        .background(HUDScrollStyle())
                        .measureHUDHeight("activity")
                    }
                    .frame(height: min(measurements["activity"] ?? 300, activityBudget))
                }
            } else {
                ScrollView(.vertical) {
                    activityBody
                        .background(HUDScrollStyle())
                        .measureHUDHeight("activity")
                }
                .frame(height: min(measurements["activity"] ?? 450, activityBudget))
            }
            panelFooter.measureHUDHeight("footer").stagger(staggerCount + 1)
        }
        .foregroundStyle(HUDStyle.text)
        .environment(\.hudRevealed, revealed)
        .padding(.horizontal, compact ? 14 : 18).padding(.top, compact ? 14 : 22).padding(.bottom, compact ? 10 : 14)
        .onPreferenceChange(HUDMeasurementsKey.self) { next in
            for (key, value) in next where value > 0 && measurements[key] != value {
                measurements[key] = value
            }
        }
    }

    private var panelHeading: some View {
        HStack {
                VStack(alignment: .leading, spacing: 5) {
                if !compact {
                    Text(usageOnly ? "SUBSCRIPTIONS" : "WORKSPACE ACTIVITY")
                        .font(.system(size: 10, weight: .medium)).tracking(1.6)
                        .foregroundStyle(HUDStyle.secondary)
                }
                HStack(spacing: 10) {
                    Text(usageOnly ? "Usage" : "Agents").font(.system(size: compact ? 18 : 24, weight: .medium))
                    Text("\(usageOnly ? usage.subs.count : store.active.count)").font(.system(size: 12))
                        .foregroundStyle(HUDStyle.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(HUDStyle.line))
                }
            }
            Spacer()
            // Pinning only means something when hovering can collapse the panel.
            if prefs.openOnHover {
                Button {
                    pinned.toggle()
                    if pinned { collapseTask?.cancel() } else { scheduleCollapse() }
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 13)).frame(width: 32, height: 32)
                        .foregroundStyle(pinned ? accentColor : HUDStyle.secondary)
                        .background(pinned ? HUDStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin panel" : "Pin panel open")
                .accessibilityLabel(pinned ? "Unpin panel" : "Pin panel open")
            }
        }
        .padding(.bottom, compact ? 12 : 20)

    }


    private var activityBody: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                if store.active.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 23)).foregroundStyle(HUDStyle.secondary)
                        Text("All quiet").font(.system(size: 14, weight: .medium))
                        Text("Start a Claude Code or Codex session to see it here.")
                            .font(.system(size: 12)).foregroundStyle(HUDStyle.secondary)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22).stagger(1)
                }
                if !attention.isEmpty {
                    sectionLabel("Needs you", count: attention.count, tint: HUDStyle.amber).stagger(1)
                    if HUDLayout.scrollsAttention(count: attention.count) {
                        ScrollView(.vertical) {
                            attentionCards.background(HUDScrollStyle())
                        }
                        .frame(height: attentionViewport)
                        .accessibilityLabel("Needs you sessions")
                        .padding(.bottom, 18)
                    } else {
                        attentionCards.padding(.bottom, 18)
                    }
                }
                if !working.isEmpty {
                    sectionLabel("Working", count: working.count).stagger(1 + attention.count)
                    sessionList(working, staggerFrom: 1 + attention.count)
                }
                if !completed.isEmpty {
                    sectionLabel("Completed", count: completed.count)
                        .padding(.top, working.isEmpty ? 0 : 14)
                        .stagger(1 + attention.count + working.count)
                    sessionList(completed, staggerFrom: 1 + attention.count + working.count)
                }
                if !store.recent.isEmpty {
                    Button { showRecent.toggle() } label: {
                        HStack(spacing: 7) {
                            Text("Recent")
                            Text("\(store.recent.count)")
                            Spacer()
                            Image(systemName: showRecent ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 11)).foregroundStyle(HUDStyle.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(showRecent ? "Hide" : "Show") \(store.recent.count) recent sessions")
                    .stagger(staggerCount)
                    if showRecent { sessionList(store.recent).stagger(staggerCount) }
                }
            }
        }
    }

    private var attentionCards: some View {
        VStack(spacing: minimal ? 4 : 8) {
            ForEach(Array(attention.enumerated()), id: \.element.id) { index, session in
                attentionCard(session).measureHUDHeight("card-" + session.id).stagger(1 + index)
            }
        }
        .padding(1) // Preserve glass edge highlights inside the scroll clipping area.
    }

    private var panelFooter: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if !usage.subs.isEmpty { usageBar }
            }
            guardBar
            HStack(spacing: 6) {
                NotchHUDLogo().foregroundStyle(HUDStyle.secondary)
                Text("NotchHUD").font(.system(size: 11, weight: .medium)).foregroundStyle(HUDStyle.secondary)
                Spacer()
                footerIcon("gearshape", key: "settings", help: "Settings") {
                    // The panel gets out of the way; settings is a normal window.
                    collapseTask?.cancel()
                    pinned = false
                    expanded = false
                    SettingsWindowController.shared.show(configStore: store.configStore, store: store)
                }
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26)
                        .foregroundStyle(hoveredRow == "quit" ? HUDStyle.text : HUDStyle.secondary)
                        .background(hoveredRow == "quit" ? HUDStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredRow = $0 ? "quit" : (hoveredRow == "quit" ? nil : hoveredRow) }
                .help("Quit NotchHUD")
                .accessibilityLabel("Quit NotchHUD")
            }.padding(.top, 6)
        }
    }

    private func footerIcon(_ symbol: String, key: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26)
                .foregroundStyle(hoveredRow == key ? HUDStyle.text : HUDStyle.secondary)
                .background(hoveredRow == key ? HUDStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRow = $0 ? key : (hoveredRow == key ? nil : hoveredRow) }
        .help(help)
        .accessibilityLabel(help)
    }

    private func sectionLabel(_ title: String, count: Int, tint: Color = HUDStyle.secondary) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: "%02d", count)).monospacedDigit()
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 4).padding(.bottom, compact ? 5 : 8)
    }

    /// Number of activity items above the Recent section; used to stagger what follows.
    private var staggerCount: Int { 1 + attention.count + working.count + completed.count }

    private func sessionList(_ sessions: [AgentSession], staggerFrom: Int? = nil) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, s in
                Group {
                    if index > 0, !minimal { HUDStyle.line.frame(height: 1).padding(.leading, 48) }
                    sessionButton(s)
                }
                .stagger(staggerFrom.map { $0 + index })
            }
        }
    }

    /// One line per session: icon, title, path, then state and time.
    private func minimalRow(_ s: AgentSession, urgent: Bool) -> some View {
        HStack(spacing: 8) {
            toolIcon(s, size: 16)
            Text(s.title).font(.system(size: 12, weight: .medium)).lineLimit(1).layoutPriority(1)
            if let email = s.account, store.config.isCrossover(email: email, path: s.cwd) {
                Image(systemName: "person.fill.questionmark").font(.system(size: 10)).foregroundStyle(HUDStyle.amber)
                    .help(store.config.label(forEmail: email) + " — account differs from repository context")
            }
            Text(s.shortPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(HUDStyle.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if urgent {
                Text(s.state == .permission ? "Approval" : "Reply")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(HUDStyle.amber)
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(HUDStyle.amber)
            } else if s.isLive, s.state == .working {
                WorkingDot(color: accentColor).frame(width: 11, height: 11)
            } else if s.isLive {
                Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Palette.done)
            } else {
                Text("Ended").font(.system(size: 10)).foregroundStyle(HUDStyle.secondary)
            }
            Text(s.isLive ? s.elapsed : s.agoText).monospacedDigit()
                .font(.system(size: 10)).foregroundStyle(HUDStyle.secondary)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func sessionButton(_ s: AgentSession, urgent: Bool = false) -> some View {
        Button { focus(s) } label: {
            if minimal {
                minimalRow(s, urgent: urgent)
                    .background(!urgent && hoveredRow == s.id ? HUDStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            } else {
                fullRow(s, urgent: urgent)
            }
        }
        .buttonStyle(.plain)
        .disabled(hostName(s) == nil)
        .onHover { if !urgent { hoveredRow = $0 ? s.id : (hoveredRow == s.id ? nil : hoveredRow) } }
        .help(rowHelp(s))
        .accessibilityLabel("\(s.title), \(s.isLive ? s.state.rawValue : "Ended"), \(focusLabel(s))")
    }

    /// Minimal rows carry what the full layout shows inline in their tooltip.
    private func rowHelp(_ s: AgentSession) -> String {
        var lines = [s.cwd]
        if minimal {
            if let title = s.conversationTitle, !title.isEmpty { lines.insert(title, at: 0) }
            if let email = s.account { lines.append(store.config.label(forEmail: email) + " · " + email) }
            if let detail = s.detail, !detail.isEmpty { lines.append(detail) }
        }
        lines.append(focusLabel(s))
        return lines.joined(separator: "\n")
    }

    private func fullRow(_ s: AgentSession, urgent: Bool) -> some View {
            HStack(alignment: .center, spacing: 11) {
                toolIcon(s)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !compact, let title = s.conversationTitle, !title.isEmpty {
                        Text(title).font(.system(size: 12)).foregroundStyle(HUDStyle.secondary).lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        if let email = s.account {
                            let crossover = store.config.isCrossover(email: email, path: s.cwd)
                            if crossover { Image(systemName: "person.fill.questionmark").foregroundStyle(HUDStyle.amber) }
                            Text(store.config.label(forEmail: email))
                                .foregroundStyle(crossover ? HUDStyle.amber : HUDStyle.secondary)
                                .help(email + (crossover ? " — account differs from repository context" : ""))
                            Text("·")
                        }
                        Text(s.shortPath).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(HUDStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 7) {
                    if urgent {
                        Image(systemName: "arrow.up.right").foregroundStyle(HUDStyle.amber)
                    } else if s.isLive, s.state == .working {
                        WorkingDot(color: accentColor).frame(height: 11)
                    } else if s.isLive {
                        Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(Palette.done)
                    } else {
                        Text("Ended")
                    }
                    Text(s.isLive ? s.elapsed : s.agoText).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(HUDStyle.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, compact ? 7 : 12)
            .background(!urgent && hoveredRow == s.id ? HUDStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }

    private func toolIcon(_ s: AgentSession, size: CGFloat = 23) -> some View {
        Group {
            if let icon = ToolIcons.icon(bundleId: s.tool == .claude ? "com.anthropic.claudefordesktop" : store.config.codexApp) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                Image(systemName: s.tool == .claude ? "sparkle" : "terminal")
                    .font(.system(size: size * 0.65)).foregroundStyle(HUDStyle.secondary)
            }
        }
        .frame(width: size + 6, height: size + 6)
        .background(HUDStyle.raised, in: RoundedRectangle(cornerRadius: size > 18 ? 8 : 5))
        .help(s.tool == .claude ? "Claude Code" : "Codex")
    }

    private func hostName(_ s: AgentSession) -> String? {
        guard let host = s.host, !host.isEmpty else { return nil }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: host).first,
           let name = app.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    private func focusLabel(_ s: AgentSession) -> String {
        hostName(s).map { "Open in \($0)" } ?? "Host unavailable"
    }

    @ViewBuilder
    private func attentionCard(_ s: AgentSession) -> some View {
        if minimal {
            // One amber-edged line; the request text lives in the tooltip and the panel stays scannable.
            sessionButton(s, urgent: true)
                .background { attentionSurface(highlighted: hoveredRow == s.id) }
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hoveredRow = $0 ? s.id : (hoveredRow == s.id ? nil : hoveredRow) }
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(light: 0xE9D5B6, dark: 0x443A2C)))
        } else {
            fullAttentionCard(s)
        }
    }

    private func fullAttentionCard(_ s: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionButton(s, urgent: true)
            VStack(alignment: .leading, spacing: 10) {
                Label(s.state == .permission ? "Approval requested" : "Waiting for your reply",
                      systemImage: s.state == .permission ? "pause.circle" : "bubble.left")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(HUDStyle.amber)
                if let detail = s.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Button { focus(s) } label: {
                    HStack {
                        Text("\(focusLabel(s))")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(HUDStyle.amber)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(light: 0xD7C19E, dark: 0x574832)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(hostName(s) == nil)
            }.padding(.leading, 50).padding(.trailing, 12).padding(.bottom, 12)
        }
        .background { attentionSurface(highlighted: hoveredRow == s.id) }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hoveredRow = $0 ? s.id : (hoveredRow == s.id ? nil : hoveredRow) }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(light: 0xE9D5B6, dark: 0x443A2C)))
    }

    @ViewBuilder
    private func attentionSurface(highlighted: Bool) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: minimal ? 7 : 12)
        let tint = highlighted
            ? Color(light: 0xF5E8D3, dark: 0x363025)
            : Color(light: 0xFBF3E6, dark: 0x26221D)
        if reduceTransparency {
            cardShape.fill(tint)
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(HUDStyle.amber.opacity(highlighted ? 0.22 : 0.12)), in: cardShape)
                .overlay { cardShape.fill(tint.opacity(highlighted ? 0.40 : 0.56)) }
        } else {
            cardShape.fill(.regularMaterial)
                .overlay { cardShape.fill(tint.opacity(highlighted ? 0.60 : 0.74)) }
        }
    }

    private var usageBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(usageValueMode == .remaining ? "Left · 5 hour / Weekly" : "5 hour / Weekly")
                    .font(.system(size: 10)).foregroundStyle(HUDStyle.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: min(3, max(1, usage.subs.count))), alignment: .leading, spacing: 16) {
                ForEach(usage.subs) { sub in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(sub.lane.provider == .codex ? "Codex" : "Claude").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 5) {
                            Circle().fill(sub.lane.accent.color).frame(width: 6, height: 6)
                            Text(sub.lane.label).font(.system(size: 10)).foregroundStyle(HUDStyle.secondary).lineLimit(1)
                        }.help(sub.lane.label)
                        if prefs.usageMeter == .rings {
                            usageRings(sub)
                        } else {
                            usageWindow(sub.fiveHour, name: "5h", accent: sub.lane.accent.color)
                            usageWindow(sub.weekly, name: "Week", accent: sub.lane.accent.color)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        // A lifted card: a surface in the panel's own tone (so no new color is
        // introduced) casts a real shadow, with a hairline border and a faint
        // light edge on top the way raised material catches light.
        .background {
            let card = RoundedRectangle(cornerRadius: 12)
            card.fill(HUDStyle.background.opacity(colorScheme == .dark ? 0.72 : 0.85))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.18), radius: 14, y: 6)
                .overlay(card.strokeBorder(HUDStyle.line))
                .overlay(
                    card.strokeBorder(
                        LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.6), .clear],
                                       startPoint: .top, endPoint: .center)
                    )
                )
        }
        .padding(.top, 14)
        .help("Active Claude login and Codex use provider reports. Other Claude accounts use transcript estimates; ≈ indicates tokens, not a percentage.")
    }

    private func usageWindow(_ window: WindowUsage?, name: String, accent: Color) -> some View {
        // Expired windows disappear immediately even between tracker refreshes.
        let w = window.flatMap { $0.resetsAt > Date() ? $0 : nil }
        // Lane color while fine; amber and red are state, not identity.
        let tint = w?.limitHit == true ? Palette.mismatch : (w?.percent ?? 0) > 60 ? HUDStyle.amber : accent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 10)).foregroundStyle(HUDStyle.secondary)
                Spacer(minLength: 2)
                Text(w.map { $0.valueText(usageValueMode) } ?? "—")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(w?.limitHit == true ? Palette.mismatch : HUDStyle.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(HUDStyle.line)
                    if let fraction = meterFraction(w) {
                        Capsule().fill(tint).frame(width: geo.size.width * fraction)
                    }
                    // Where the fill "should" be if quota and time ran together.
                    if let tick = tickFraction(w) {
                        RoundedRectangle(cornerRadius: 1).fill(HUDStyle.secondary)
                            .frame(width: 2, height: 8)
                            .offset(x: geo.size.width * tick - 1)
                    }
                }
            }.frame(height: 4)
            Text(w.map { resetText($0.resetsAt) } ?? "No current data")
                .font(.system(size: 10)).foregroundStyle(HUDStyle.secondary)
                .lineLimit(1).minimumScaleFactor(0.9)
            if let w, !w.splits.isEmpty { splitText(w, size: 10) }
            if let pace = w.flatMap(paceText) {
                Text(pace).font(.system(size: 10)).foregroundStyle(HUDStyle.amber)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.top, 3)
        .help(w.map { windowHelp($0, name: name) } ?? "No current \(name) usage reported")
        .accessibilityElement(children: .combine)
    }

    /// Per-model caps under the week ("Fable 37%"), amber once one runs hot.
    private func splitText(_ w: WindowUsage, size: CGFloat) -> some View {
        let hot = w.splits.contains { $0.percent > 60 }
        return Text(w.splits.map { $0.valueText(usageValueMode) }.joined(separator: " · "))
            .font(.system(size: size)).foregroundStyle(hot ? HUDStyle.amber : HUDStyle.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .help("Per-model weekly caps. The tightest one binds before the overall week does.")
    }

    /// Tick position in the meter's own direction: elapsed time in Used mode,
    /// time left in Remaining mode, so fill and tick always compare directly.
    private func tickFraction(_ w: WindowUsage?) -> CGFloat? {
        guard let w, w.percent != nil else { return nil }
        let elapsed = w.elapsedFraction()
        return CGFloat(usageValueMode == .remaining ? 1 - elapsed : elapsed)
    }

    /// One amber line, only when quota is going faster than the window.
    private func paceText(_ w: WindowUsage) -> String? {
        guard case .ahead(let limitAt) = w.pace() else { return nil }
        return "At this pace, limit in \(durationText(until: limitAt))"
    }

    private func windowHelp(_ w: WindowUsage, name: String) -> String {
        var text = "\(name) resets \(w.resetsAt.formatted(date: .abbreviated, time: .shortened)) · \(Int((w.elapsedFraction() * 100).rounded()))% of the window has passed."
        switch w.pace() {
        case .onPace(let spare): text += " On pace: about \(Int((max(0, spare) * 100).rounded()))% would be left at the reset."
        case .ahead(let limitAt): text += " Faster than the window: the limit lands around \(limitAt.formatted(date: .omitted, time: .shortened))."
        case .unknown: break
        }
        return text
    }

    /// Two concentric rings: the 5-hour window outside, the week inside, the
    /// tightest window's percent in the middle. Reset times sit beside it so
    /// a glance at the ring answers "how much", the legend "until when".
    private func usageRings(_ sub: SubscriptionUsage) -> some View {
        let fiveHour = sub.fiveHour.flatMap { $0.resetsAt > Date() ? $0 : nil }
        let weekly = sub.weekly.flatMap { $0.resetsAt > Date() ? $0 : nil }
        let accent = sub.lane.accent.color
        let tightest = [fiveHour, weekly].compactMap { $0 }.max { ($0.tightestPercent ?? -1) < ($1.tightestPercent ?? -1) }
        let centerText: String = {
            guard let t = tightest else { return "—" }
            if t.limitHit { return "Limit" }
            guard let percent = t.tightestPercent else { return "≈\(t.tokensText)" }
            return usageValueMode == .remaining ? "\(max(0, Int((100 - percent).rounded(.down))))%" : String(format: "%.0f%%", percent)
        }()
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                ring(fiveHour, accent: accent, diameter: 54, lineWidth: 5)
                ring(weekly, accent: accent.opacity(0.55), diameter: 38, lineWidth: 5)
                Text(centerText)
                    .font(.system(size: centerText.count > 3 ? 7 : 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tightest?.limitHit == true ? Palette.mismatch : HUDStyle.text)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 26)
            }
            .frame(width: 54, height: 54)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                ringLegend(fiveHour, name: "5h", swatch: accent)
                ringLegend(weekly, name: "Week", swatch: accent.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sub.lane.label): 5 hour \(fiveHour.map { $0.valueText(usageValueMode) } ?? "no data"), week \(weekly.map { $0.valueText(usageValueMode) } ?? "no data")")
    }

    private func ring(_ w: WindowUsage?, accent: Color, diameter: CGFloat, lineWidth: CGFloat) -> some View {
        let tint = w?.limitHit == true ? Palette.mismatch : (w?.tightestPercent ?? 0) > 60 ? HUDStyle.amber : accent
        return ZStack {
            Circle().stroke(HUDStyle.line, lineWidth: lineWidth)
            if let fraction = meterFraction(w) {
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let tick = tickFraction(w) {
                Circle().fill(HUDStyle.secondary).frame(width: 3, height: 3)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(Double(tick) * 360))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func ringLegend(_ w: WindowUsage?, name: String, swatch: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle().strokeBorder(swatch, lineWidth: 2).frame(width: 8, height: 8)
                Text(name).font(.system(size: 10)).foregroundStyle(HUDStyle.secondary)
                Text(w.map { $0.valueText(usageValueMode) } ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(w?.limitHit == true ? Palette.mismatch : HUDStyle.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(w.map { resetText($0.resetsAt) } ?? "No current data")
                .font(.system(size: 9)).foregroundStyle(HUDStyle.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let w, !w.splits.isEmpty { splitText(w, size: 9) }
            if let pace = w.flatMap(paceText) {
                Text(pace).font(.system(size: 9)).foregroundStyle(HUDStyle.amber)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .help(w.map { windowHelp($0, name: name) } ?? "No current \(name) usage reported")
    }

    /// How much of the meter is filled: spent quota in Used mode, what is
    /// left in Remaining mode (so the bar drains and agrees with the number).
    /// A limit with no percent fills in Used mode and empties in Remaining.
    private func meterFraction(_ w: WindowUsage?) -> CGFloat? {
        guard let w else { return nil }
        let used: Double
        if let fraction = w.fraction { used = fraction }
        else if w.limitHit { used = 1 }
        else { return nil }
        let shown = usageValueMode == .remaining ? 1 - used : used
        return CGFloat(max(0, min(1, shown)))
    }

    private func resetText(_ date: Date) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSinceNow / 60)))
        if minutes < 1440 { return "Resets in \(durationText(until: date))" }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func durationText(until date: Date) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSinceNow / 60)))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }

    private var guardBar: some View {
        let g = store.guardStatus
        let mismatch = g.level == .mismatch
        let tint = mismatch ? Palette.mismatch : g.level == .ok ? Palette.okGreen : HUDStyle.secondary
        return HStack(spacing: 9) {
            Image(systemName: mismatch ? "exclamationmark.shield" : g.level == .ok ? "checkmark.shield" : "info.circle")
                .font(.system(size: 15)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(mismatch ? "GitHub CLI default differs" : (g.activeAccount == "?" ? "GitHub CLI" : "GitHub CLI · \(g.activeAccount)")).font(.system(size: 12, weight: .medium))
                Text(mismatch ? "Using \(g.activeAccount) · expects \(g.expectedAccount ?? "unknown")" : g.level == .ok ? "Default matches this repo’s rule" : (g.context.isEmpty ? "Identity not verified" : g.context))
                    .font(.system(size: 11)).foregroundStyle(HUDStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if mismatch, let expected = g.expectedAccount {
                Button("Switch") { onSwitchAccount(expected) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                    .padding(7).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.4)))
                    .help("Switch GitHub account to \(expected)")
            } else if g.level == .ok {
                Text("Matches").font(.system(size: 10)).foregroundStyle(tint)
            }
        }
        .padding(.vertical, 13)
        .help(g.text + "\nChecks the saved gh CLI default, not Git user.email, SSH keys, or session token overrides.")
    }
}

private extension View {
    /// Cascade position within the panel; `nil` leaves the view unstaggered.
    @ViewBuilder
    func stagger(_ index: Int?) -> some View {
        if let index { modifier(StaggerReveal(index: index)) } else { self }
    }
}
