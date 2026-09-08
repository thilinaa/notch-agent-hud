import Foundation

/// Polls ~/.codex/sessions rollout files. A file being written = the session is live.
/// Fresh writes -> working; quiet for a bit -> needs input; quiet for long -> gone.
@MainActor
final class CodexWatcher {
    private struct RolloutMeta {
        var cwd = ""
        var isSubagent = false
        var title: String?
        var originator = ""
        /// True once there's nothing more to learn — stop re-parsing the file.
        var settled = false

        /// Sessions from the Codex desktop app (vs. the CLI in a terminal).
        var isDesktop: Bool { originator.lowercased().contains("desktop") }
    }

    private weak var store: SessionStore?
    private var timer: Timer?
    private var metaCache: [String: RolloutMeta] = [:]
    private var known: Set<String> = []
    private var hostCache: [String: String] = [:]
    private var targetCache: [String: String] = [:]
    private var hostsRefreshed = Date.distantPast
    private var scanning = false

    private let workingWindow: TimeInterval = 20
    private let liveWindow: TimeInterval = 30 * 60

    init(store: SessionStore) {
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        Task { await scan() }
    }

    private var sessionRoot: String { NSHomeDirectory() + "/.codex/sessions" }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        if Date().timeIntervalSince(hostsRefreshed) >= 15 {
            let hosts = await SessionHostResolver.snapshot()
            hostCache = hosts.rollouts
            targetCache = hosts.rolloutTargets
            store?.resolveClaudeHosts(hosts.claudeProcesses, targets: hosts.claudeTargets)
            hostsRefreshed = Date()
        }
        let fm = FileManager.default
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy/MM/dd"

        // Last 7 days: fresh files are live sessions, older ones feed "recent".
        var dirs: [String] = []
        for offset in 0...6 {
            if let day = cal.date(byAdding: .day, value: -offset, to: Date()) {
                dirs.append(sessionRoot + "/" + fmt.string(from: day))
            }
        }

        var liveSeen: Set<String> = []
        let now = Date()
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") && f.hasPrefix("rollout-") {
                let path = dir + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let age = now.timeIntervalSince(mtime)
                let id = String(f.dropFirst("rollout-".count).dropLast(".jsonl".count))

                let meta = meta(forFile: path, id: id, isStale: age >= liveWindow)
                if meta.isSubagent { continue } // internal judge/guardian runs, not user sessions
                let host = hostCache[path] ?? (meta.isDesktop ? store?.config.codexApp : nil)

                if age < liveWindow {
                    liveSeen.insert(id)
                    known.insert(id)
                    let state: SessionState = age < workingWindow ? .working : .needsInput
                    store?.codexUpdate(id: id, cwd: meta.cwd, state: state, title: meta.title, host: host,
                                       account: activeCodexAccount(), targetID: targetCache[path])
                } else {
                    store?.codexEnded(id: id, cwd: meta.cwd, at: mtime, title: meta.title, host: host)
                }
            }
        }

        // Files that vanished while live (deleted/moved): end them now.
        for id in known.subtracting(liveSeen) {
            store?.codexEnded(id: id, cwd: "", at: Date())
            known.remove(id)
        }
    }

    /// Parses the rollout head: session cwd, whether it's an internal subagent
    /// run, and the first real user prompt (used as the session title).
    private func meta(forFile path: String, id: String, isStale: Bool) -> RolloutMeta {
        if let cached = metaCache[id], cached.settled { return cached }

        var m = metaCache[id] ?? RolloutMeta()
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 256 * 1024) else { return m }
        try? handle.close()

        let text = String(decoding: data, as: UTF8.self)
        for (i, line) in text.split(separator: "\n").enumerated() {
            if i > 200 || m.isSubagent || m.title != nil { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if type == "session_meta" {
                m.cwd = payload["cwd"] as? String ?? m.cwd
                m.originator = payload["originator"] as? String ?? m.originator
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                    m.isSubagent = true
                }
            } else if type == "response_item",
                      payload["type"] as? String == "message",
                      payload["role"] as? String == "user" {
                let content = payload["content"] as? [[String: Any]] ?? []
                let prompt = content.compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip injected context blocks like <environment_context>.
                if !prompt.isEmpty, !prompt.hasPrefix("<") {
                    m.title = Self.condense(prompt)
                }
            }
        }

        // Nothing more will show up: subagent, title found, or the file is old.
        m.settled = m.isSubagent || m.title != nil || isStale
        metaCache[id] = m
        return m
    }

    // MARK: - Active codex account (email from the auth.json JWT)

    private var accountCache: (mtime: Date, email: String?)?

    private func activeCodexAccount() -> String? {
        let path = NSHomeDirectory() + "/.codex/auth.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let cached = accountCache, cached.mtime == mtime { return cached.email }

        var email: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            email = Self.findJWTEmail(in: obj)
        }
        accountCache = (mtime, email)
        return email
    }

    /// Scans values for JWTs and returns the first "email" claim found.
    private static func findJWTEmail(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for v in dict.values {
                if let email = findJWTEmail(in: v) { return email }
            }
        } else if let str = value as? String, str.split(separator: ".").count == 3, str.count > 100 {
            let segment = String(str.split(separator: ".")[1])
            var b64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
            if let data = Data(base64Encoded: b64),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let email = payload["email"] as? String { return email }
                if let profile = payload["https://api.openai.com/profile"] as? [String: Any],
                   let email = profile["email"] as? String { return email }
            }
        }
        return nil
    }

    private static func condense(_ prompt: String) -> String {
        var t = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        // Collapse plugin-mention markdown: [@Gmail](plugin://…) -> @Gmail
        t = t.replacingOccurrences(
            of: #"\[(@[^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > 64 {
            t = String(t.prefix(64)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return t
    }
}
