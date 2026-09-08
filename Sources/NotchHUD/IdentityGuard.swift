import Foundation

/// Compares the active `gh` account against the account the guard-target repo expects.
@MainActor
final class IdentityGuard {
    private weak var store: SessionStore?
    private var timer: Timer?
    private var ownerCache: [String: String?] = [:]

    init(store: SessionStore) {
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let target = store?.guardTarget
        let cwd = target?.cwd ?? ""
        let config = store?.config ?? HUDConfig()
        Task.detached { [config, cachedOwner = ownerCache[cwd]] in
            let active = Self.activeGhAccount() ?? "?"
            let owner = cachedOwner ?? Self.repoOwner(cwd: cwd)
            let expected = cwd.isEmpty ? nil : config.expectedGhAccount(forPath: cwd, owner: owner)

            var status = GuardStatus()
            status.activeAccount = active
            status.expectedAccount = expected
            if active == "?" {
                status.level = .unknown
                status.context = "No saved GitHub CLI default"
            } else if let expected {
                let repoRef = owner.map { "\($0)/\((cwd as NSString).lastPathComponent)" } ?? Self.shortPath(cwd)
                if expected == active {
                    status.level = .ok
                    status.context = "matches \(repoRef)"
                } else {
                    status.level = .mismatch
                    status.context = repoRef
                }
            } else {
                status.level = .unknown
                status.context = config.rules.isEmpty
                    ? "No account rules configured"
                    : cwd.isEmpty ? "No active session" : "No account rule for this repository"
            }

            let resolvedOwner = owner
            let finalStatus = status
            await MainActor.run { [weak self] in
                if !cwd.isEmpty { self?.ownerCache[cwd] = resolvedOwner }
                self?.store?.guardStatus = finalStatus
            }
        }
    }

    func switchAccount(to account: String) {
        Task.detached {
            _ = Self.run("/usr/bin/env", ["gh", "auth", "switch", "--hostname", "github.com", "--user", account])
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    // MARK: - System probes (run off the main actor)

    nonisolated private static func activeGhAccount() -> String? {
        let env = ProcessInfo.processInfo.environment
        let configRoot = env["GH_CONFIG_DIR"]
            ?? env["XDG_CONFIG_HOME"].map { $0 + "/gh" }
            ?? NSHomeDirectory() + "/.config/gh"
        guard let text = try? String(contentsOfFile: configRoot + "/hosts.yml", encoding: .utf8) else { return nil }
        return parseDefaultAccount(text)
    }

    /// Only github.com's direct `user` field is the selected default. Nested
    /// entries under `users` are saved logins and must not be treated as active.
    nonisolated static func parseDefaultAccount(_ text: String) -> String? {
        var inGithub = false
        var fieldIndent: Int?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inGithub = trimmed == "github.com:"
                fieldIndent = nil
                continue
            }
            guard inGithub else { continue }
            if fieldIndent == nil { fieldIndent = indent }
            guard indent == fieldIndent, trimmed.hasPrefix("user:") else { continue }
            let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// /usr/bin/git is a stub that pops the developer-tools installer when no
    /// toolchain is present; a background HUD must never trigger that.
    nonisolated private static let gitAvailable: Bool = {
        run("/usr/bin/xcode-select", ["-p"]) != nil
    }()

    nonisolated private static func repoOwner(cwd: String) -> String? {
        guard !cwd.isEmpty, gitAvailable else { return nil }
        guard let url = run("/usr/bin/git", ["-C", cwd, "config", "--get", "remote.origin.url"]) else { return nil }
        // git@github.com:owner/repo.git or https://github.com/owner/repo.git
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = ""
        if let r = trimmed.range(of: "github.com:") {
            tail = String(trimmed[r.upperBound...])
        } else if let r = trimmed.range(of: "github.com/") {
            tail = String(trimmed[r.upperBound...])
        } else {
            return nil
        }
        return tail.split(separator: "/").first.map(String.init)
    }

    nonisolated private static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    @discardableResult
    nonisolated private static func run(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
