import Foundation
import Combine

/// Starts a Claude 5-hour window on a schedule so it is already running when
/// you sit down. A window opens with the first message, and whether that
/// message is "hi" at 07:00 or real work at 09:00 it ends five hours later;
/// saying hi early means the window you start the day with already has two
/// hours behind it and the next one lands mid-afternoon instead of at dinner.
/// The message is one word sent with `claude -p` from a scratch directory,
/// costing a few tokens. Skipped when a window is already running.
@MainActor
final class WarmupScheduler: ObservableObject {
    static let shared = WarmupScheduler()

    struct Run: Codable, Identifiable, Equatable {
        var id: String { slot + "@" + String(at.timeIntervalSince1970) }
        /// "2026-09-10 07:00" for a scheduled slot, or "manual".
        let slot: String
        let at: Date
        let outcome: String
        let ok: Bool
    }

    @Published private(set) var runs: [Run] = []
    @Published private(set) var running = false

    private weak var usage: UsageTracker?
    private weak var configStore: ConfigStore?
    private var timer: Timer?
    static var directory: String { Home.directory + "/.notchhud/warmup" }
    private var stateURL: URL { URL(fileURLWithPath: Home.directory + "/.notchhud/warmup-runs.json") }

    private init() {}

    func start(usage: UsageTracker, configStore: ConfigStore) {
        self.usage = usage
        self.configStore = configStore
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode([Run].self, from: data) {
            runs = saved
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Give the usage tracker a moment to learn whether a window is live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    // MARK: Schedule

    /// Slot keys ("yyyy-MM-dd HH:mm") that are due: their time has passed today,
    /// less than `graceMinutes` ago (a Mac asleep at 07:00 still warms up at
    /// 07:40, but not at noon), on an allowed weekday. Pure, for tests.
    nonisolated static func dueSlots(times: [String], weekdaysOnly: Bool, graceMinutes: Int,
                                     now: Date, calendar: Calendar = .current) -> [String] {
        let weekday = calendar.component(.weekday, from: now)
        if weekdaysOnly, weekday == 1 || weekday == 7 { return [] }
        var due: [String] = []
        for time in times {
            guard let (h, m) = parseTime(time),
                  let slot = calendar.date(bySettingHour: h, minute: m, second: 0, of: now) else { continue }
            let age = now.timeIntervalSince(slot)
            if age >= 0, age <= Double(graceMinutes) * 60 {
                due.append(slotKey(slot, calendar: calendar))
            }
        }
        return due
    }

    nonisolated static func parseTime(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let h = parts[0], let m = parts[1],
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    nonisolated static func slotKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    private func tick(now: Date = Date()) {
        guard let config = configStore?.config, config.warmup.enabled, !running else { return }
        let done = Set(runs.map { $0.slot })
        let due = Self.dueSlots(times: config.warmup.times, weekdaysOnly: config.warmup.weekdaysOnly,
                                graceMinutes: config.warmup.graceMinutes, now: now)
        guard let slot = due.first(where: { !done.contains($0) }) else { return }
        if let live = liveWindowDescription() {
            record(Run(slot: slot, at: now, outcome: "Skipped: \(live)", ok: true))
            return
        }
        perform(slot: slot)
    }

    /// "5-hour window already running (39%, resets in 54m)" for the active
    /// Claude login, or nil when no window is live (or nothing is known).
    private func liveWindowDescription() -> String? {
        guard let usage, let config = configStore?.config else { return nil }
        let lane = AccountDetection.activeClaudeEmail().map { config.lane(forEmail: $0).id } ?? Lane.unknownID
        guard let sub = usage.subs.first(where: { $0.lane.id == lane }),
              let w = sub.fiveHour, w.resetsAt > Date(),
              (w.percent ?? 0) > 0 || (w.tokens ?? 0) > 0 else { return nil }
        let minutes = max(1, Int(w.resetsAt.timeIntervalSinceNow / 60))
        let value = w.percent.map { "\(Int($0.rounded()))%" } ?? "≈\(w.tokensText)"
        return "a 5-hour window is already running (\(value), resets in \(minutes / 60)h \(minutes % 60)m)"
    }

    /// Settings → Run now. Ignores the live-window check: the user asked.
    func runNow() {
        guard !running else { return }
        perform(slot: "manual")
    }

    private func perform(slot: String) {
        running = true
        let dir = Self.directory
        Task.detached {
            let result = Self.sayHi(in: dir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.running = false
                self.record(Run(slot: slot, at: Date(), outcome: result.message, ok: result.ok))
                // Let the new window show up in the usage card without waiting a minute.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.usage?.refresh() }
            }
        }
    }

    /// Runs `claude -p hi` in the scratch directory through a login shell so
    /// the same `claude` the terminal sees is used. Two minutes, then give up.
    nonisolated private static func sayHi(in dir: String) -> (ok: Bool, message: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec claude -p 'hi' --output-format text"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                       env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "Could not start a shell: \(error.localizedDescription)") }
        let deadline = DispatchTime.now() + 120
        let group = DispatchGroup()
        group.enter()
        p.terminationHandler = { _ in group.leave() }
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return (false, "Timed out after two minutes; is `claude` signed in?")
        }
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = out.fileHandleForReading.readDataToEndOfFile()
        if p.terminationStatus == 0 { return (true, "Started a 5-hour window") }
        if p.terminationStatus == 127 || stderr.contains("command not found") {
            return (false, "`claude` was not found on PATH")
        }
        let reason = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
        return (false, "Failed: \(reason.prefix(120))")
    }

    private func record(_ run: Run) {
        runs.append(run)
        if runs.count > 30 { runs.removeFirst(runs.count - 30) }
        if let data = try? JSONEncoder().encode(runs) { try? data.write(to: stateURL, options: .atomic) }
    }
}
