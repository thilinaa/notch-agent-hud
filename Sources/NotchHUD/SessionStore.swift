import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var guardStatus = GuardStatus()

    let configStore: ConfigStore
    var config: HUDConfig { configStore.config }
    private var byId: [String: AgentSession] = [:]
    private var ticker: Timer?
    private var configSink: AnyCancellable?

    private var storeURL: URL {
        URL(fileURLWithPath: Home.directory + "/.notchhud/sessions.json")
    }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        // Labels, lanes and rules come from the config; re-render when it changes.
        configSink = configStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        loadSessions()
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        // Reconcile soon after launch so restored sessions get fresh states quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reconcile()
        }
    }

    var active: [AgentSession] {
        sessions.filter { $0.isLive }
    }

    /// Recent = missing-lane representatives. Every subscription lane (personal
    /// Claude, work Claude, Codex, …) stays visible: a lane with no ongoing
    /// session shows its most recent ended one here — regardless of how many
    /// other lanes' sessions are active. No duplicates (a lane with an active
    /// session gets no recent row; a recent whose directory matches an active
    /// session is skipped), and nothing older than the 7-day retention.
    var recent: [AgentSession] {
        let activeLanes = Set(active.map { laneKey($0) })
        let activeCwds = Set(active.map { $0.cwd }.filter { !$0.isEmpty })

        var newestPerLane: [String: AgentSession] = [:]
        for s in sessions where !s.isLive {
            guard let ended = s.endedAt else { continue }
            let lane = laneKey(s)
            guard !activeLanes.contains(lane) else { continue }
            guard !activeCwds.contains(s.cwd) else { continue }
            if let current = newestPerLane[lane], (current.endedAt ?? .distantPast) >= ended { continue }
            newestPerLane[lane] = s
        }
        return newestPerLane.values
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// Which subscription lane a session belongs to for the recents picker.
    private func laneKey(_ s: AgentSession) -> String {
        config.laneID(for: s)
    }

    var loudest: SessionState? {
        let live = active
        if live.contains(where: { $0.state == .permission }) { return .permission }
        if live.contains(where: { $0.state == .needsInput }) { return .needsInput }
        if live.contains(where: { $0.state == .working }) { return .working }
        return live.isEmpty ? nil : .done
    }

    // MARK: - Claude Code hook events

    func apply(hookEvent obj: [String: Any]) {
        guard let event = obj["hook_event_name"] as? String else { return }
        let id = (obj["session_id"] as? String) ?? "unknown"
        let cwd = (obj["cwd"] as? String) ?? byId[id]?.cwd ?? ""
        // The scheduled warm-up's "hi" is bookkeeping, not a session to watch.
        if cwd == WarmupScheduler.directory { return }

        switch event {
        case "SessionEnd":
            if var s = byId[id] {
                s.endedAt = Date()
                s.state = .done
                s.detail = nil
                byId[id] = s
            }
        case "SessionStart", "UserPromptSubmit":
            upsert(id: id, tool: .claude, cwd: cwd, state: .working, detail: nil, revives: true)
        case "Stop", "SubagentStop":
            // Hooks are independent processes: a Stop can land after SessionEnd
            // and must not bring the session back from the dead.
            upsert(id: id, tool: .claude, cwd: cwd, state: .needsInput, detail: nil, revives: false)
        case "Notification":
            let message = (obj["message"] as? String) ?? ""
            let lower = message.lowercased()
            if lower.contains("permission") || lower.contains("approve") {
                upsert(id: id, tool: .claude, cwd: cwd, state: .permission, detail: message)
            } else if lower.contains("waiting") || lower.contains("input") {
                upsert(id: id, tool: .claude, cwd: cwd, state: .needsInput, detail: nil)
            } else {
                upsert(id: id, tool: .claude, cwd: cwd, state: .needsInput, detail: message)
            }
        default:
            break
        }

        if let host = obj["_host"] as? String, !host.isEmpty, var s = byId[id] {
            s.host = host
            byId[id] = s
        }
        if let pid = obj["_pid"] as? Int, pid > 0, var s = byId[id] {
            s.pid = pid
            byId[id] = s
        }
        // First event wins: the account active when the session started.
        if let acc = obj["_account"] as? String, !acc.isEmpty, var s = byId[id], s.account == nil {
            s.account = acc
            byId[id] = s
        }
        if let transcript = obj["transcript_path"] as? String, var s = byId[id] {
            s.transcriptPath = transcript
            byId[id] = s
            // Titles appear after the first turn and can be regenerated later.
            if s.conversationTitle == nil || event == "Stop" {
                fetchTitle(id: id, path: transcript)
            }
        }
        publish()
    }

    private func fetchTitle(id: String, path: String) {
        Task.detached {
            guard let title = Self.extractTitle(path: path) else { return }
            await MainActor.run { [weak self] in
                guard let self, var s = self.byId[id], s.conversationTitle != title else { return }
                s.conversationTitle = title
                self.byId[id] = s
                self.publish()
            }
        }
    }

    /// Last `"aiTitle":"…"` in the transcript (scans head + tail, titles are small).
    nonisolated private static func extractTitle(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let window = 262_144
        var chunks: [Data] = []
        if let head = try? fh.read(upToCount: window) { chunks.append(head) }
        if let size = try? fh.seekToEnd(), size > UInt64(window * 2) {
            try? fh.seek(toOffset: size - UInt64(window))
            if let tail = try? fh.readToEnd() { chunks.append(tail) }
        }
        var best: String?
        for chunk in chunks {
            let text = String(decoding: chunk, as: UTF8.self)
            var searchFrom = text.startIndex
            while let r = text.range(of: "\"aiTitle\":\"", range: searchFrom..<text.endIndex) {
                let rest = text[r.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    let candidate = String(rest[..<end])
                    if !candidate.isEmpty { best = candidate }
                }
                searchFrom = r.upperBound
            }
        }
        return best
    }

    /// Repair missing hook host metadata using the reported live Claude PID.
    func resolveClaudeHosts(_ hosts: [Int32: String], targets: [Int32: String]) {
        var changed = false
        for (id, var session) in byId where session.isLive && session.tool == .claude {
            guard let pid = session.pid, let processID = Int32(exactly: pid),
                  let host = hosts[processID] else { continue }
            let target = targets[processID]
            guard session.host != host || session.hostTargetID != target else { continue }
            session.host = host
            session.hostTargetID = target
            byId[id] = session
            changed = true
        }
        if changed { publish() }
    }

    // MARK: - Codex

    func codexUpdate(id: String, cwd: String, state: SessionState, title: String? = nil, host: String? = nil, account: String? = nil, targetID: String? = nil) {
        let key = "codex-" + id
        upsert(id: key, tool: .codex, cwd: cwd, state: state, detail: nil)
        if var s = byId[key] {
            if let title { s.conversationTitle = title }
            if let host { s.host = host; s.hostTargetID = targetID }
            if let account, s.account == nil { s.account = account }
            byId[key] = s
        }
        publish()
    }

    /// A codex rollout that went quiet or disappeared: keep it as a recent entry.
    func codexEnded(id: String, cwd: String, at date: Date, title: String? = nil, host: String? = nil) {
        let key = "codex-" + id
        if var s = byId[key] {
            var changed = false
            if let title, s.conversationTitle == nil {
                s.conversationTitle = title
                changed = true
            }
            if let host, s.host != host {
                s.host = host
                changed = true
            }
            if s.isLive {
                s.endedAt = date
                s.state = .done
                changed = true
            }
            guard changed else { return }
            byId[key] = s
        } else {
            var s = AgentSession(
                id: key, tool: .codex, cwd: cwd, state: .done, detail: nil,
                startedAt: date, lastEvent: date
            )
            s.endedAt = date
            s.conversationTitle = title
            s.host = host
            byId[key] = s
        }
        publish()
    }

    // MARK: - Internals

    private func upsert(id: String, tool: AgentTool, cwd: String, state: SessionState, detail: String?, revives: Bool = true) {
        if var s = byId[id] {
            if !s.isLive && !revives { return }
            s.state = state
            s.detail = detail
            s.lastEvent = Date()
            s.endedAt = nil // a new turn revives a "recent" entry (e.g. --resume)
            if !cwd.isEmpty { s.cwd = cwd }
            byId[id] = s
        } else {
            byId[id] = AgentSession(
                id: id, tool: tool, cwd: cwd, state: state, detail: detail,
                startedAt: Date(), lastEvent: Date()
            )
        }
    }

    /// Self-healing pass: hook events can be lost (HUD restarts, crashes), so
    /// states are periodically checked against reality instead of trusted forever.
    private func reconcile() {
        let now = Date()
        for (key, var s) in byId {
            var changed = false

            if s.isLive, s.tool == .claude {
                // The claude process died without a SessionEnd event.
                if let pid = s.pid, pid > 0, kill(pid_t(pid), 0) == -1, errno == ESRCH {
                    s.endedAt = s.lastEvent
                    s.state = .done
                    changed = true
                } else if s.state == .working, let path = s.transcriptPath,
                          let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date,
                          now.timeIntervalSince(mtime) > 120 {
                    // A working session writes its transcript constantly; a quiet
                    // transcript means the turn ended and we missed the Stop event.
                    s.state = .needsInput
                    changed = true
                }
            }

            if s.isLive, now.timeIntervalSince(s.lastEvent) > 4 * 3600 {
                // Went away without a SessionEnd — treat as ended back then.
                s.endedAt = s.lastEvent
                s.state = .done
                changed = true
            }
            if let ended = s.endedAt, now.timeIntervalSince(ended) > 7 * 86400 {
                byId.removeValue(forKey: key)
                continue
            }
            if changed { byId[key] = s }
        }
        publish()
    }

    private func publish() {
        sessions = byId.values.sorted { $0.startedAt < $1.startedAt }
        saveSessions()
    }

    /// The session whose repo the identity guard should check: the one that most recently did something.
    var guardTarget: AgentSession? {
        active.max { $0.lastEvent < $1.lastEvent } ?? recent.first
    }

    // MARK: - Persistence (~/.notchhud/sessions.json)

    private func loadSessions() {
        // Migrate from the old recents-only file if present.
        let legacy = URL(fileURLWithPath: Home.directory + "/.notchhud/recent.json")
        let url = FileManager.default.fileExists(atPath: storeURL.path) ? storeURL : legacy
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([AgentSession].self, from: data) else { return }
        for s in stored {
            byId[s.id] = s
        }
        try? FileManager.default.removeItem(at: legacy)
        sessions = byId.values.sorted { $0.startedAt < $1.startedAt }
    }

    private func saveSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        do {
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("NotchHUD: could not save sessions: %@", error.localizedDescription)
        }
    }
}
