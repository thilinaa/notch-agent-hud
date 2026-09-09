import Foundation

enum AgentTool: String, Codable {
    case claude
    case codex
}

enum SessionState: String, Codable {
    case working = "Working"
    case permission = "Permission"
    case needsInput = "Needs input"
    case done = "Done"
}

struct AgentSession: Identifiable, Codable {
    let id: String
    let tool: AgentTool
    var cwd: String
    var state: SessionState
    var detail: String?
    var startedAt: Date
    var lastEvent: Date
    var transcriptPath: String? = nil
    var conversationTitle: String? = nil
    /// Bundle id of the app hosting the session (from __CFBundleIdentifier).
    var host: String? = nil
    /// Stable host-native terminal handle, when the host exposes one.
    var hostTargetID: String? = nil
    /// Set when the session ends; kept around as a "recent" entry.
    var endedAt: Date? = nil
    /// The claude process's pid (from the hook relay), for liveness checks.
    var pid: Int? = nil
    /// Claude account email active when the session started (from the relay).
    var account: String? = nil

    var isLive: Bool { endedAt == nil }

    var agoText: String {
        let ref = endedAt ?? lastEvent
        let s = Int(Date().timeIntervalSince(ref))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// Terminal hosts get tab/window matching; other apps get plain activation.
    var isTerminalHost: Bool {
        guard let host, !host.isEmpty else { return true }
        let h = host.lowercased()
        let terminals = ["ghostty", "iterm", "apple.terminal", "warp", "kitty", "wezterm", "alacritty"]
        return terminals.contains { h.contains($0) }
    }

    var title: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }

    var shortPath: String {
        let home = Home.directory
        var p = cwd
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        // Show at most the last three components for long paths.
        let parts = p.split(separator: "/")
        if parts.count > 4 {
            return (p.hasPrefix("~") ? "~/…/" : "…/") + parts.suffix(2).joined(separator: "/")
        }
        return p
    }

    var elapsed: String {
        let s = Int(Date().timeIntervalSince(startedAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

enum GuardLevel {
    case ok
    case mismatch
    case unknown
}

struct GuardStatus {
    var level: GuardLevel = .unknown
    var activeAccount: String = "…"
    var expectedAccount: String?
    var context: String = ""

    var text: String {
        switch level {
        case .ok:
            return "gh: \(activeAccount) ✓  \(context)"
        case .mismatch:
            return "gh: \(activeAccount) ✗  expected \(expectedAccount ?? "?")"
        case .unknown:
            return context.isEmpty ? "gh: \(activeAccount)" : "gh: \(activeAccount) · \(context)"
        }
    }
}
