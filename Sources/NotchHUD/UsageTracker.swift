import Foundation
import Combine

/// One usage window (5-hour or weekly) of one subscription.
struct WindowUsage {
    let resetsAt: Date
    let limitHit: Bool
    /// Used-percent: authoritative (Codex) or ceiling-derived (Claude after a 429 taught the cap).
    var percent: Double? = nil
    /// Estimated tokens burned (Claude); shown when no percent is available.
    var tokens: Int? = nil
    /// Window length: five hours, or a week for the weekly window.
    var length: TimeInterval = WindowUsage.fiveHours

    static let fiveHours: TimeInterval = 5 * 3600
    static let oneWeek: TimeInterval = 7 * 86400

    var fraction: Double? { percent.map { min(1.0, $0 / 100) } }

    /// How far through the window we are, 0 at its start and 1 at the reset.
    func elapsedFraction(at now: Date = Date()) -> Double {
        guard length > 0 else { return 0 }
        return max(0, min(1, 1 - resetsAt.timeIntervalSince(now) / length))
    }

    /// Spending compared with the passage of time. "Ahead" means the quota is
    /// going faster than the window, and names the moment it runs out at the
    /// current rate. Silent for the first tenth of a window, when two messages
    /// at 07:01 would otherwise project a limit by lunch.
    enum Pace: Equatable {
        case unknown
        /// Quota outlasts the window; `spare` is the fraction still unspent at the reset.
        case onPace(spare: Double)
        case ahead(limitAt: Date)
    }

    func pace(at now: Date = Date()) -> Pace {
        guard let used = fraction, !limitHit else { return .unknown }
        let elapsed = elapsedFraction(at: now)
        guard elapsed >= 0.1, used > 0 else { return .unknown }
        let projected = used / elapsed
        // Time already spent, scaled by what is left to burn versus what went.
        let elapsedTime = length * elapsed
        let untilLimit = elapsedTime * (1 - used) / used
        let limitAt = now.addingTimeInterval(untilLimit)
        // A limit landing within the last twentieth of the window is a wash,
        // not a warning; the caption should not flap around the line.
        if projected <= 1 || resetsAt.timeIntervalSince(limitAt) < length * 0.05 {
            return .onPace(spare: 1 - projected)
        }
        return .ahead(limitAt: limitAt)
    }
    /// Whole-number percent left, floored so "1% left" never rounds up to "0% left" while usable.
    var remainingPercent: Int? { percent.map { max(0, Int((100 - $0).rounded(.down))) } }

    /// The number a lane shows for this window, in the user's chosen mode.
    /// Token estimates have no ceiling, so they read the same either way.
    func valueText(_ mode: UsageValueMode) -> String {
        if limitHit { return "Limit" }
        if let percent {
            switch mode {
            case .used: return String(format: "%.0f%%", percent)
            case .remaining: return "\(remainingPercent ?? 0)% left"
            }
        }
        return "≈\(tokensText)"
    }

    var tokensText: String {
        let t = tokens ?? 0
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK", Double(t) / 1_000) }
        return "\(t)"
    }
}

/// A subscription row in the usage strip: its lane + its two windows.
struct SubscriptionUsage: Identifiable {
    var id: String { lane.id }
    let lane: Lane
    let fiveHour: WindowUsage?
    let weekly: WindowUsage?
}

/// Estimates Claude usage per account by summing token counts from transcripts,
/// grouped into Anthropic-style 5-hour blocks (block = 5h from the first message
/// after the previous block ended, floored to the hour). A 429 in a transcript
/// supplies the exact reset time and teaches the block ceiling.
@MainActor
final class UsageTracker: ObservableObject {
    @Published private(set) var subs: [SubscriptionUsage] = []

    private weak var store: SessionStore?
    private var config: HUDConfig { store?.config ?? HUDConfig() }
    private var timer: Timer?
    private var configSink: AnyCancellable?

    // Per-file scan cursor so each pass only reads appended bytes.
    private struct FileCursor { var offset: UInt64 }
    private var cursors: [String: FileCursor] = [:]
    // (timestamp, tokens, lane) events inside the lookback horizon.
    private var events: [(ts: Date, tokens: Int, lane: String)] = []
    private var seenMessageIds: Set<String> = []
    // Rate-limit sightings: lane -> (resetsAt, tokensAtRejection)
    private var limits: [String: (resetsAt: Date, tokensAt: Int)] = [:]
    // Weekly (seven_day) limit sightings: lane -> resetsAt.
    private var weeklyLimits: [String: Date] = [:]
    // Learned ceilings persisted across restarts.
    private var ceilings: [String: Int] = [:]

    private let horizon: TimeInterval = 12 * 3600
    private let blockLength: TimeInterval = 5 * 3600
    private var ceilingURL: URL { URL(fileURLWithPath: Home.directory + "/.notchhud/usage-ceilings.json") }

    init(store: SessionStore) {
        self.store = store
        if let data = try? Data(contentsOf: ceilingURL),
           let c = try? JSONDecoder().decode([String: Int].self, from: data) {
            ceilings = Self.rekeyCeilings(c, config: store.config)
        }
        // Renamed or hidden subscriptions change rows without new data.
        configSink = store.configStore.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.recompute() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scan()
                self?.fetchClaudeAPIUsage()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scan()
            self?.fetchClaudeAPIUsage()
        }
    }

    /// Ceilings were keyed by v1 labels ("WORK"); move them to subscription ids
    /// so a rename does not forget a learned cap. Unknown keys are kept as-is.
    nonisolated static func rekeyCeilings(_ old: [String: Int], config: HUDConfig) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in old {
            if config.subscription(id: key) != nil || key.hasPrefix(Lane.unlabeledPrefix) {
                out[key] = max(out[key] ?? 0, value)
            } else if let sub = config.subscriptions.first(where: { $0.provider == .claude && $0.label == key }) {
                out[sub.id] = max(out[sub.id] ?? 0, value)
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// Lane id for a transcript: the account stamped on its session, else the
    /// login active right now.
    private func laneFor(transcript path: String) -> String {
        if let s = store?.sessions.first(where: { $0.transcriptPath == path }), let email = s.account {
            return config.lane(forEmail: email).id
        }
        return activeClaudeLane()
    }

    private var scanning = false

    private func scan() {
        guard !scanning else { return }  // a slow pass must not overlap the next
        scanning = true
        let fm = FileManager.default
        let root = Home.directory + "/.claude/projects"
        let cutoff = Date().addingTimeInterval(-horizon)

        var files: [String] = []
        for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + project
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let path = dir + "/" + f
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date, mtime > cutoff {
                    files.append(path)
                }
            }
        }

        let snapshot = cursors
        let laneMap = Dictionary(uniqueKeysWithValues: files.map { ($0, laneFor(transcript: $0)) })

        Task.detached { [weak self, files, snapshot, laneMap] in
            var newEvents: [(Date, Int, String, String)] = []   // ts, tokens, msgid, lane
            var newLimits: [(String, Date, String)] = []        // lane, resetsAt, path
            var updated = snapshot

            for path in files {
                let lane = laneMap[path] ?? Lane.unknownID
                guard let fh = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? fh.close() }
                let size = (try? fh.seekToEnd()) ?? 0
                var cursor = updated[path] ?? FileCursor(
                    offset: size > 4_000_000 ? size - 4_000_000 : 0  // first sight of a big file: tail only
                )
                if cursor.offset > size { cursor.offset = 0 }  // truncated/rotated
                guard size > cursor.offset else { updated[path] = cursor; continue }
                try? fh.seek(toOffset: cursor.offset)
                guard let data = try? fh.readToEnd() else { continue }
                // Don't consume a trailing partial line; leave it for the next pass.
                var consumed = data.count
                if data.last != 0x0A, let lastNL = data.lastIndex(of: 0x0A) {
                    consumed = lastNL + 1
                }
                cursor.offset += UInt64(consumed)
                updated[path] = cursor

                let text = String(decoding: data.prefix(consumed), as: UTF8.self)
                for line in text.split(separator: "\n") {
                    if line.contains("\"usage\"") && line.contains("\"assistant\"") {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              let msg = obj["message"] as? [String: Any],
                              let usage = msg["usage"] as? [String: Any] else { continue }
                        let msgid = msg["id"] as? String ?? UUID().uuidString
                        let ts = (obj["timestamp"] as? String).flatMap(Self.parseISO) ?? Date()
                        let tokens = (usage["input_tokens"] as? Int ?? 0)
                            + (usage["output_tokens"] as? Int ?? 0)
                            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                        if tokens > 0 { newEvents.append((ts, tokens, msgid, lane)) }
                    }
                    if line.contains("\"rateLimitType\":\""),
                       let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                        func find(_ o: Any, _ key: String) -> Any? {
                            if let d = o as? [String: Any] {
                                if let r = d[key] { return r }
                                for v in d.values { if let r = find(v, key) { return r } }
                            }
                            return nil
                        }
                        if let epoch = find(obj, "resetsAt") as? Double {
                            let type = find(obj, "rateLimitType") as? String ?? "five_hour"
                            newLimits.append((lane, Date(timeIntervalSince1970: epoch), type))
                        }
                    }
                }
            }

            let codex = Self.scanCodexLimits()
            let events = newEvents
            let limits = newLimits
            let cursors = updated
            await MainActor.run { [weak self] in
                self?.scanning = false
                self?.ingest(events: events, limits: limits, cursors: cursors, codex: codex)
            }
        }
    }

    struct CodexWindow: Sendable {
        let label: String       // "5h" / "1w"
        let percent: Double
        let resetsAt: Date
    }

    private var codexWindows: [CodexWindow] = []

    // Authoritative Claude usage from the OAuth endpoint, for the ACTIVE login
    // only (read-only Keychain access — other accounts stay estimate-based).
    private var apiByLane: [String: ClaudeUsageAPI.Windows] = [:]
    private var lastAPIFetch: Date = .distantPast
    /// Grows after failures so a denied Keychain prompt or an offline Mac is
    /// not retried every two minutes; resets on the next success.
    private var apiRetryInterval: TimeInterval = 120

    private func fetchClaudeAPIUsage() {
        guard config.preferences.useUsageAPI else {
            if !apiByLane.isEmpty { apiByLane = [:]; recompute() }
            return
        }
        guard Date().timeIntervalSince(lastAPIFetch) > apiRetryInterval else { return }
        lastAPIFetch = Date()
        let lane = activeClaudeLane()
        Task.detached { [weak self] in
            let windows = await ClaudeUsageAPI.fetch()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let windows {
                    // The active login moved? Keep only the current lane's data.
                    self.apiByLane = [lane: windows]
                    self.apiRetryInterval = 120
                } else {
                    self.apiRetryInterval = min(self.apiRetryInterval * 2, 3600)
                }
                self.recompute()
            }
        }
    }

    /// Lane of the login Claude Code is using now (honours CLAUDE_CONFIG_DIR like the relay does).
    private func activeClaudeLane() -> String {
        AccountDetection.activeClaudeEmail().map { config.lane(forEmail: $0).id } ?? Lane.unknownID
    }

    /// Codex reports authoritative usage in its rollouts: the last `token_count`
    /// event's `rate_limits` carries used_percent + resets_at for the 5h and
    /// weekly windows. Read the freshest one from the newest rollout files.
    nonisolated private static func scanCodexLimits() -> [CodexWindow] {
        let fm = FileManager.default
        let root = Home.directory + "/.codex/sessions"
        let cutoff = Date().addingTimeInterval(-7 * 86400)

        // Newest rollout files by mtime, at most 6.
        var candidates: [(path: String, mtime: Date)] = []
        if let e = fm.enumerator(atPath: root) {
            for case let rel as String in e where rel.hasSuffix(".jsonl") {
                let path = root + "/" + rel
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date, mtime > cutoff {
                    candidates.append((path, mtime))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        for (path, _) in candidates.prefix(6) {
            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            let tail: UInt64 = 512 * 1024
            try? fh.seek(toOffset: size > tail ? size - tail : 0)
            guard let data = try? fh.readToEnd() else { continue }
            let text = String(decoding: data, as: UTF8.self)
            // Last populated rate_limits line wins.
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"rate_limits\":{"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any] else { continue }
                // Newer codex versions put rate_limits beside "info"; older inside it.
                let rlAny = payload["rate_limits"]
                    ?? (payload["info"] as? [String: Any])?["rate_limits"]
                guard let rl = rlAny as? [String: Any] else { continue }
                var out: [CodexWindow] = []
                for (key, label) in [("primary", "5h"), ("secondary", "1w")] {
                    if let w = rl[key] as? [String: Any],
                       let pct = w["used_percent"] as? Double,
                       let resets = w["resets_at"] as? Double {
                        let resetDate = Date(timeIntervalSince1970: resets)
                        if resetDate > Date() {  // still-current window only
                            out.append(CodexWindow(label: label, percent: pct, resetsAt: resetDate))
                        }
                    }
                }
                if !out.isEmpty { return out }
            }
        }
        return []
    }

    private func ingest(events newEvents: [(Date, Int, String, String)],
                        limits newLimits: [(String, Date, String)],
                        cursors updated: [String: FileCursor],
                        codex: [CodexWindow]) {
        cursors = updated
        codexWindows = codex
        for (ts, tokens, msgid, lane) in newEvents where !seenMessageIds.contains(msgid) {
            seenMessageIds.insert(msgid)
            events.append((ts, tokens, lane))
        }
        let cutoff = Date().addingTimeInterval(-horizon)
        events.removeAll { $0.ts < cutoff }
        if seenMessageIds.count > 50_000 { seenMessageIds.removeAll() }  // cheap reset; dedupe re-learns

        for (lane, resetsAt, type) in newLimits where resetsAt > Date() {
            if type == "five_hour" {
                let burned = currentBlockTokens(lane: lane)?.tokens ?? 0
                limits[lane] = (resetsAt, burned)
                if burned > 0, burned > (ceilings[lane] ?? 0) / 2 {
                    ceilings[lane] = burned
                    if let data = try? JSONEncoder().encode(ceilings) {
                        try? data.write(to: ceilingURL, options: .atomic)
                    }
                }
            } else {
                // seven_day / weekly variants
                weeklyLimits[lane] = resetsAt
            }
        }

        recompute()
    }

    private func currentBlockTokens(lane: String) -> (tokens: Int, start: Date)? {
        let laneEvents = events.filter { $0.lane == lane }.sorted { $0.ts < $1.ts }
        guard !laneEvents.isEmpty else { return nil }
        // Walk forward assigning events to 5h blocks; keep the block containing now.
        var blockStart = Self.floorToHour(laneEvents[0].ts)
        var tokens = 0
        for e in laneEvents {
            if e.ts >= blockStart.addingTimeInterval(blockLength) {
                blockStart = Self.floorToHour(e.ts)
                tokens = 0
            }
            tokens += e.tokens
        }
        guard Date() < blockStart.addingTimeInterval(blockLength) else { return nil }
        return (tokens, blockStart)
    }

    private func recompute() {
        var result: [SubscriptionUsage] = []
        for lane in Set(events.map { $0.lane }) {
            guard let block = currentBlockTokens(lane: lane) else { continue }
            let limit = limits[lane]
            let limitActive = (limit?.resetsAt ?? .distantPast) > Date()
            var fiveHour = WindowUsage(
                resetsAt: limitActive ? limit!.resetsAt : block.start.addingTimeInterval(blockLength),
                limitHit: limitActive,
                tokens: block.tokens
            )
            if let c = ceilings[lane], c > 0 {
                fiveHour.percent = min(100, Double(block.tokens) / Double(c) * 100)
            }
            // Claude's weekly window is only visible when a seven_day 429 was seen.
            var weekly: WindowUsage?
            if let resets = weeklyLimits[lane], resets > Date() {
                weekly = WindowUsage(resetsAt: resets, limitHit: true, length: WindowUsage.oneWeek)
            }
            // Authoritative API data for this lane overrides estimates.
            if let api = apiByLane[lane] {
                if let fh = api.fiveHour, fh.resetsAt > Date() {
                    fiveHour = WindowUsage(resetsAt: fh.resetsAt, limitHit: fh.percent >= 100,
                                           percent: fh.percent, tokens: block.tokens)
                }
                if let wk = api.weekly, wk.resetsAt > Date() {
                    weekly = WindowUsage(resetsAt: wk.resetsAt, limitHit: wk.percent >= 100,
                                         percent: wk.percent, length: WindowUsage.oneWeek)
                }
            }
            result.append(SubscriptionUsage(lane: config.lane(id: lane), fiveHour: fiveHour, weekly: weekly))
        }
        // Accounts with API usage but no tracked session events still get a row.
        for (lane, api) in apiByLane where !result.contains(where: { $0.lane.id == lane }) {
            let fh = api.fiveHour.flatMap { $0.resetsAt > Date()
                ? WindowUsage(resetsAt: $0.resetsAt, limitHit: $0.percent >= 100, percent: $0.percent) : nil }
            let wk = api.weekly.flatMap { $0.resetsAt > Date()
                ? WindowUsage(resetsAt: $0.resetsAt, limitHit: $0.percent >= 100, percent: $0.percent,
                              length: WindowUsage.oneWeek) : nil }
            if fh != nil || wk != nil {
                result.append(SubscriptionUsage(lane: config.lane(id: lane), fiveHour: fh, weekly: wk))
            }
        }
        result.sort {
            ($0.fiveHour?.percent ?? Double($0.fiveHour?.tokens ?? 0) / 1_000_000)
                > ($1.fiveHour?.percent ?? Double($1.fiveHour?.tokens ?? 0) / 1_000_000)
        }

        if !codexWindows.isEmpty {
            func window(_ label: String) -> WindowUsage? {
                codexWindows.first { $0.label == label }.map {
                    WindowUsage(resetsAt: $0.resetsAt, limitHit: $0.percent >= 100, percent: $0.percent,
                                length: label == "1w" ? WindowUsage.oneWeek : WindowUsage.fiveHours)
                }
            }
            result.append(SubscriptionUsage(lane: config.codexLane, fiveHour: window("5h"), weekly: window("1w")))
        }
        // Hidden subscriptions keep being tracked; they just don't get a row.
        subs = result.filter { $0.lane.visible }
    }

    nonisolated private static func parseISO(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: s) ?? {
            let plain = ISO8601DateFormatter()
            return plain.date(from: s)
        }()
    }

    nonisolated private static func floorToHour(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}
