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

        var out = Windows()
        out.fiveHour = window(in: obj, keys: ["five_hour", "fiveHour"])
        out.weekly = window(in: obj, keys: ["seven_day", "sevenDay", "seven_day_overall"])
        // Some plans report only model-split weekly windows; take the fullest one.
        if out.weekly == nil {
            let candidates = obj.keys.filter { $0.hasPrefix("seven_day") }
            out.weekly = candidates
                .compactMap { window(in: obj, keys: [$0]) }
                .max { $0.percent < $1.percent }
        }
        return (out.fiveHour == nil && out.weekly == nil) ? nil : out
    }

    nonisolated private static func window(in obj: [String: Any], keys: [String]) -> (Double, Date)? {
        for key in keys {
            guard let w = obj[key] as? [String: Any] else { continue }
            let pct = (w["utilization"] as? Double)
                ?? (w["used_percent"] as? Double)
                ?? (w["utilization"] as? Int).map(Double.init)
            guard let pct else { continue }
            var resets: Date?
            if let iso = w["resets_at"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resets = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
            } else if let epoch = w["resets_at"] as? Double {
                resets = Date(timeIntervalSince1970: epoch)
            }
            if let resets, resets > Date() {
                return (pct, resets)
            }
        }
        return nil
    }
}
