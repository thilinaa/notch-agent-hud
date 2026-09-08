import AppKit
import ApplicationServices
import Foundation

// MARK: - Claude Code hooks

/// Installs and inspects the hook relay: `~/.notchhud/notify.sh` plus the
/// entries in `~/.claude/settings.json` that call it. Mirrors
/// `scripts/install-hooks.sh` so the app can do it from Setup.
enum HookInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]

    static var relayPath: String { NSHomeDirectory() + "/.notchhud/notify.sh" }
    static var settingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

    enum Status: Equatable {
        case installed
        case partial(missing: [String])
        case notInstalled
        case settingsUnreadable
    }

    static func status(settings settingsPath: String = settingsPath, relay relayPath: String = relayPath) -> Status {
        guard FileManager.default.fileExists(atPath: relayPath) else { return .notInstalled }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)) else { return .notInstalled }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .settingsUnreadable }
        let hooks = (obj["hooks"] as? [String: Any]) ?? [:]
        let missing = events.filter { event in
            !((hooks[event] as? [[String: Any]]) ?? []).contains { isRelay($0, relayPath: relayPath) }
        }
        if missing.count == events.count { return .notInstalled }
        return missing.isEmpty ? .installed : .partial(missing: missing)
    }

    /// Ours: the relay path, an older relay location, or the original inline
    /// curl form. Deliberately not "anything mentioning notchhud".
    static func isRelay(_ entry: [String: Any], relayPath: String) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
            let command = ($0["command"] as? String) ?? ""
            return command == relayPath
                || command.hasSuffix("/.notchhud/notify.sh")
                || (command.contains("127.0.0.1:") && command.contains("/event"))
        }
    }

    /// Pure merge: removes stale NotchHUD entries, appends one per event, keeps
    /// every other hook untouched.
    static func merge(settings: [String: Any], relayPath: String) -> [String: Any] {
        var settings = settings
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            var entries = ((hooks[event] as? [[String: Any]]) ?? []).filter { !isRelay($0, relayPath: relayPath) }
            entries.append(["hooks": [["type": "command", "command": relayPath]]])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        return settings
    }

    static func relayScript(port: UInt16) -> String {
        """
        #!/bin/sh
        HOST="${__CFBundleIdentifier:-}"
        # Active Claude account (respects CLAUDE_CONFIG_DIR overrides).
        CFG="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
        ACC=$(plutil -extract oauthAccount.emailAddress raw -o - "$CFG" 2>/dev/null)
        # Find the claude process in our ancestry for liveness checks.
        PID=$PPID
        CLPID=0
        i=0
        while [ $i -lt 5 ] && [ "$PID" -gt 1 ] 2>/dev/null; do
          NAME=$(ps -o comm= -p "$PID" 2>/dev/null)
          case "$NAME" in *claude*) CLPID=$PID; break;; esac
          PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
          [ -z "$PID" ] && break
          i=$((i+1))
        done
        sed "s/^{/{\\"_host\\":\\"$HOST\\",\\"_pid\\":$CLPID,\\"_account\\":\\"$ACC\\",/" | curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:\(port)/event" >/dev/null 2>&1
        exit 0

        """
    }

    /// Writes the relay and merges the hooks. The previous settings file is
    /// kept as a timestamped `.bak`. Throws with a readable message.
    static func install(port: UInt16, settings settingsPath: String = settingsPath, relay relayPath: String = relayPath) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (relayPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try relayScript(port: port).write(toFile: relayPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relayPath)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SetupError("~/.claude/settings.json is not valid JSON; fix it first so nothing is lost.")
            }
            settings = obj
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try? data.write(to: URL(fileURLWithPath: settingsPath + ".bak." + stamp))
            pruneBackups(of: settingsPath, keep: 5)
        } else {
            try fm.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let merged = merge(settings: settings, relayPath: relayPath)
        // Keep the user's file recognisable: no escaped slashes, no reordering beyond what JSON needs.
        let out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .withoutEscapingSlashes])
        try (out + Data("\n".utf8)).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    /// Old `settings.json.bak.<stamp>` copies beyond the newest `keep` are removed.
    static func pruneBackups(of settingsPath: String, keep: Int) {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        let prefix = (settingsPath as NSString).lastPathComponent + ".bak."
        let fm = FileManager.default
        let backups = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        for name in backups.dropLast(keep) {
            try? fm.removeItem(atPath: dir + "/" + name)
        }
    }
}

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Accessibility

/// Terminal-tab focus needs the Accessibility grant. Read-only probe plus the
/// two ways to get there.
@MainActor
enum AccessibilityPermission {
    static var granted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its own prompt (adds the app to the list, unchecked).
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - gh accounts

extension IdentityGuard {
    /// Every saved login under github.com in `hosts.yml`, default first.
    nonisolated static func parseAllAccounts(_ text: String) -> [String] {
        var inGithub = false
        var inUsers = false
        var usersIndent: Int?
        var users: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inGithub = trimmed == "github.com:"
                inUsers = false
                usersIndent = nil
                continue
            }
            guard inGithub else { continue }
            if trimmed == "users:" { inUsers = true; usersIndent = nil; continue }
            if inUsers {
                if usersIndent == nil { usersIndent = indent }
                if indent == usersIndent, trimmed.hasSuffix(":") {
                    users.append(String(trimmed.dropLast()))
                } else if indent < (usersIndent ?? 0) {
                    inUsers = false
                }
            }
        }
        var ordered = users
        if let active = parseDefaultAccount(text), let index = ordered.firstIndex(of: active) {
            ordered.remove(at: index)
            ordered.insert(active, at: 0)
        }
        return ordered
    }

    nonisolated static func savedGhAccounts() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let configRoot = env["GH_CONFIG_DIR"]
            ?? env["XDG_CONFIG_HOME"].map { $0 + "/gh" }
            ?? NSHomeDirectory() + "/.config/gh"
        guard let text = try? String(contentsOfFile: configRoot + "/hosts.yml", encoding: .utf8) else { return [] }
        return parseAllAccounts(text)
    }
}

// MARK: - Repo rule suggestions

enum RuleSuggestions {
    /// Directory prefixes worth turning into rules: the first two path
    /// components under the home folder for every session directory, most
    /// used first, minus prefixes already covered by a rule.
    static func pathPrefixes(sessions: [AgentSession], rules: [RepoRule], home: String = NSHomeDirectory()) -> [String] {
        // System and tooling folders are never where someone keeps repos.
        let ignored: Set<String> = ["Library", "Applications", "Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures", "Public"]
        var counts: [String: Int] = [:]
        for s in sessions {
            guard s.cwd.hasPrefix(home + "/") else { continue }
            let rest = s.cwd.dropFirst(home.count + 1).split(separator: "/")
            guard let first = rest.first, !first.hasPrefix("."), !ignored.contains(String(first)) else { continue }
            counts["~/" + first, default: 0] += 1
            if rest.count >= 3 {
                counts["~/" + first + "/" + rest[1], default: 0] += 1
            }
        }
        let covered = Set(rules.filter { $0.kind == .pathPrefix }.map { $0.value })
        return counts.filter { !covered.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.key }
    }
}
