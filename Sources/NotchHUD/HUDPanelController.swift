import AppKit
import SwiftUI
import Combine

/// The floating margin around the pill so SwiftUI shadows/glows aren't clipped
/// by the window bounds. Transparent pixels pass clicks through.
private let shadowMargin: CGFloat = 72

private struct HUDRoot: View {
    let inner: HUDView
    var body: some View {
        inner
            .padding(.horizontal, shadowMargin)
            .padding(.bottom, shadowMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// One HUD panel per attached display; rebuilt when screens change.
@MainActor
final class PanelManager {
    private var controllers: [HUDPanelController] = []
    private let store: SessionStore
    private let guardian: IdentityGuard
    private let usage: UsageTracker

    init(store: SessionStore, guardian: IdentityGuard, usage: UsageTracker) {
        self.store = store
        self.guardian = guardian
        self.usage = usage
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    private func rebuild() {
        controllers.forEach { $0.close() }
        controllers = NSScreen.screens.compactMap { screen in
            guard screen.displayID != nil else { return nil }
            return HUDPanelController(store: store, guardian: guardian, usage: usage, screen: screen)
        }
    }
}

@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let hasNotch: Bool
    private let screenID: CGDirectDisplayID
    private let windowSize: NSSize

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == screenID }
    }

    init(store: SessionStore, guardian: IdentityGuard, usage: UsageTracker, screen: NSScreen) {
        screenID = screen.displayID ?? 0
        let insetTop = screen.safeAreaInsets.top
        let notch = insetTop > 1
        hasNotch = notch

        var notchWidth: CGFloat = 0
        if notch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        let pillHeight = notch ? insetTop : 30
        let collapsedWidth = notch ? notchWidth + 280 : 340
        let expandedWidth: CGFloat = max(460, collapsedWidth)
        let maxBodyHeight = max(120, screen.visibleFrame.height - pillHeight - shadowMargin * 2)

        let view = HUDView(
            store: store,
            usage: usage,
            hasNotch: notch,
            notchWidth: notchWidth,
            collapsedWidth: collapsedWidth,
            expandedWidth: expandedWidth,
            pillHeight: pillHeight,
            maxBodyHeight: maxBodyHeight,
            onFocusSession: { session in FocusHelper.focus(session: session, appName: store.config.terminalApp) },
            onSwitchAccount: { account in guardian.switchAccount(to: account) }
        )

        // The window stays at full expanded size; SwiftUI animates the pill
        // inside it (smooth slide, no window-resize jank). Transparent pixels
        // pass clicks through to whatever is underneath.
        windowSize = NSSize(
            width: max(collapsedWidth, expandedWidth) + shadowMargin * 2,
            height: pillHeight + maxBodyHeight + shadowMargin
        )

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The hosting view must fill the window and nothing more. Left to its
        // defaults it also reports the SwiftUI content's ideal size as an
        // intrinsic size; when that exceeds the fixed window (many attention
        // cards), Auto Layout grows the view past the top edge and the pill
        // ends up above the screen.
        let hosting = NSHostingView(rootView: HUDRoot(inner: view))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        applyFrame()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    private func applyFrame() {
        guard let screen else { return }
        // Notch screens: flush with the physical top. Others: hang below the menu bar.
        let top = hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY
        let frame = NSRect(
            x: (screen.frame.midX - windowSize.width / 2).rounded(),
            y: top - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }
}

@MainActor
enum FocusHelper {
    /// Switch to the terminal tab whose title mentions the session's
    /// conversation title (what Claude Code puts in the tab title), falling
    /// back to a window-title match, then to activating the app. Uses the
    /// Accessibility API in-process — the AX calls are attributed to NotchHUD
    /// itself, so the user's Accessibility grant for NotchHUD applies (an
    /// osascript child process gets its own attribution and is refused).
    static func focus(session: AgentSession, appName: String) {
        guard let host = session.host, !host.isEmpty else {
            log("focus '\(session.title)': host not detected")
            return
        }
        if host == "com.stablyai.orca", let target = session.hostTargetID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
            Task {
                let focused = await NativeSessionFocus.focusOrca(handle: target, appURL: appURL)
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
                    bringForward(running)
                }
                log("Orca focus: \(focused ? "selected recorded terminal" : "terminal unavailable; opened app only")")
            }
            return
        }
        if host == "com.mitchellh.ghostty" {
            _ = NativeSessionFocus.focusGhostty(session: session)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
                bringForward(running)
            }
            return
        }
        // Non-terminal hosts (Orca, Claude desktop, Zed, …): activate that app directly.
        if !session.isTerminalHost, let host = session.host {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: host).first {
                bringForward(running)
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
            log("focus '\(session.title)': recorded host \(host) is unavailable")
            return
        }
        // Respect the recorded terminal, even if it differs from the configured default.
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: host).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: host)?.deletingPathExtension().lastPathComponent
            ?? appName
        let fragment = session.conversationTitle ?? session.title
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            log("focus '\(fragment)': \(appName) not running — launching")
            activateTerminal(named: appName)
            return
        }
        guard AXIsProcessTrusted() else {
            log("focus '\(fragment)': NotchHUD lacks Accessibility — app-level activate only")
            app.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else {
            log("focus '\(fragment)': no AX windows")
            app.activate()
            return
        }

        for window in windows {
            if let (tab, tabIndex) = findTab(in: window, matching: fragment) {
                let wasActive = app.isActive
                let activationAccepted = bringForward(app)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    let pressResult = AXUIElementPerformAction(tab, kAXPressAction as CFString)
                    let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    let (valueResult, tabValue) = value(of: tab)
                    log("focus '\(fragment)': activation accepted=\(activationAccepted), active \(wasActive)->\(app.isActive), tab \(tabIndex + 1), press=\(pressResult.rawValue), raise=\(raiseResult.rawValue), selected=\(valueResult.rawValue)/\(tabValue)")
                }
                return
            }
        }
        for window in windows where (title(of: window) ?? "").contains(fragment) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let ok = bringForward(app)
            log("focus '\(fragment)': raised window, foreground=\(ok)")
            return
        }
        let ok = bringForward(app)
        log("focus '\(fragment)': no tab/window match — app-level activate, foreground=\(ok)")
    }

    /// The HUD panel is non-activating, and macOS refuses cross-app activation
    /// from an app that isn't active itself. The user just clicked us, so take
    /// activation briefly and formally hand it to the terminal.
    @discardableResult
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return app.activate(from: .current, options: [])
    }

    // MARK: - AX helpers

    /// Native macOS tabs: background tabs aren't AX windows, but the tab bar
    /// exposes each tab as a radio button named with its title.
    private static func findTab(in window: AXUIElement, matching fragment: String) -> (AXUIElement, Int)? {
        for group in children(of: window) where role(of: group) == "AXTabGroup" {
            let tabs = children(of: group).filter { role(of: $0) == "AXRadioButton" }
            for (index, tab) in tabs.enumerated() {
                if (title(of: tab) ?? "").contains(fragment) {
                    return (tab, index)
                }
            }
        }
        return nil
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    private static func role(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func title(of el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func value(of el: AXUIElement) -> (AXError, String) {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref)
        if let number = ref as? NSNumber {
            return (result, number.stringValue)
        }
        return (result, ref.map { String(describing: $0) } ?? "nil")
    }

    /// Appends to ~/.notchhud/focus.log, a diagnostic log for terminal focus.
    /// Capped at 256 KB: once it grows past that it starts over.
    nonisolated static func log(_ line: String) {
        let path = NSHomeDirectory() + "/.notchhud/focus.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data(entry.utf8))
            try? fh.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func activateTerminal(named name: String) {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            running.activate()
            return
        }
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
