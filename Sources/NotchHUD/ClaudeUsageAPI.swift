import Foundation

/// Fetches authoritative Claude usage (the same data Claude Code's /usage screen
/// shows): 5-hour and weekly utilization percentages with reset times, via the
/// OAuth usage endpoint, authenticated with the active login's token from the
/// Keychain. The token is read in-process and sent only to api.anthropic.com.
/// Read-only: never refreshes or writes credentials — so only the ACTIVE login
/// (whose token Claude Code keeps fresh) gets authoritative data; other
/// accounts' lanes fall back to transcript estimates. (Deliberate choice.)
enum ClaudeUsageAPI {
    struct Windows: Sendable {
        var fiveHour: (percent: Double, resetsAt: Date)?
        var weekly: (percent: Double, resetsAt: Date)?
        /// Per-model weekly caps ("Fable 37%") that sit under the overall week
        /// and can bind first. Sorted tightest first.
        var weeklySplits: [Split] = []
    }

    struct Split: Sendable, Equatable {
        let label: String
        let percent: Double
        let resetsAt: Date
    }

    /// Reads the active login's OAuth access token via the security CLI
    /// (the item Claude Code maintains for the current account).
    nonisolated private static func accessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    nonisolated static func fetch() async -> Windows? {
        guard let token = accessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ephemeral: nothing about this request or response touches the disk cache.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(obj)
    }

    /// The response shape: `five_hour` / `seven_day` objects with `utilization`
    /// and `resets_at`, plus a `limits` array whose `weekly_scoped` entries
    /// carry per-model caps. Older shapes name those `seven_day_opus` and
    /// `seven_day_sonnet` instead.
    nonisolated static func parse(_ obj: [String: Any]) -> Windows? {
        var out = Windows()
        out.fiveHour = window(in: obj, keys: ["five_hour", "fiveHour"])
        out.weekly = window(in: obj, keys: ["seven_day", "sevenDay", "seven_day_overall"])

        var splits: [Split] = []
        for entry in (obj["limits"] as? [[String: Any]]) ?? [] {
            guard entry["group"] as? String == "weekly", entry["kind"] as? String == "weekly_scoped",
                  let percent = number(entry["percent"]),
                  let resets = resetDate(entry["resets_at"]), resets > Date() else { continue }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let label = (model?["display_name"] as? String)
                ?? (model?["id"] as? String)
                ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                ?? "Scoped"
            splits.append(Split(label: label, percent: percent, resetsAt: resets))
        }
        if splits.isEmpty {
            for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                if let w = window(in: obj, keys: [key]) {
                    splits.append(Split(label: label, percent: w.0, resetsAt: w.1))
                }
            }
        }
        out.weeklySplits = splits.sorted { $0.percent > $1.percent }

        // Some plans report only model-split weekly windows; take the fullest one.
        if out.weekly == nil {
            let candidates = obj.keys.filter { $0.hasPrefix("seven_day") }
            out.weekly = candidates
                .compactMap { window(in: obj, keys: [$0]) }
                .max { $0.percent < $1.percent }
        }
        return (out.fiveHour == nil && out.weekly == nil) ? nil : out
    }

    nonisolated private static func number(_ v: Any?) -> Double? {
        (v as? Double) ?? (v as? Int).map(Double.init)
    }

    nonisolated private static func resetDate(_ v: Any?) -> Date? {
        if let iso = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        }
        if let epoch = v as? Double { return Date(timeIntervalSince1970: epoch) }
        return nil
    }

    nonisolated private static func window(in obj: [String: Any], keys: [String]) -> (Double, Date)? {
        for key in keys {
            guard let w = obj[key] as? [String: Any] else { continue }
            guard let pct = number(w["utilization"]) ?? number(w["used_percent"]) else { continue }
            if let resets = resetDate(w["resets_at"]), resets > Date() {
                return (pct, resets)
            }
        }
        return nil
    }
}
