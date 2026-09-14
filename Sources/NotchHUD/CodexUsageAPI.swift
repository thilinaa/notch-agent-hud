import Foundation

/// Exact Codex usage, the numbers the Codex app shows: the account's rate
/// limit windows plus any per-model pools, from the endpoint the app itself
/// uses, authenticated with the token Codex keeps in `~/.codex/auth.json`.
/// Read-only: the file is read in process, the token sent only to
/// chatgpt.com, and nothing is written. Rollout reports remain the fallback
/// when this is off or fails; they lag whenever the last session used a
/// per-model pool, which is why this exists.
enum CodexUsageAPI {
    struct Credentials {
        let accessToken: String
        let accountID: String?
    }

    nonisolated static func credentials(home: String = Home.directory) -> Credentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.codex/auth.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return Credentials(accessToken: token, accountID: tokens["account_id"] as? String)
    }

    nonisolated static func fetch() async -> [UsageTracker.CodexWindow]? {
        guard let creds = credentials(),
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = creds.accountID { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = parse(obj)
        return windows.isEmpty ? nil : windows
    }

    /// `rate_limit.primary_window` / `secondary_window` carry `used_percent`,
    /// `limit_window_seconds` and `reset_at`; `additional_rate_limits` lists
    /// per-model pools with a `limit_name` and the same window shape. Pools
    /// with usage become splits under the matching account window.
    nonisolated static func parse(_ obj: [String: Any], now: Date = Date()) -> [UsageTracker.CodexWindow] {
        guard let main = obj["rate_limit"] as? [String: Any] else { return [] }
        var windows = accountWindows(in: main, now: now)
        for pool in (obj["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            guard let rl = pool["rate_limit"] as? [String: Any] else { continue }
            let label = (pool["limit_name"] as? String)
                ?? (pool["metered_feature"] as? String).map { $0.replacingOccurrences(of: "codex_", with: "") }
                ?? "Model"
            for w in accountWindows(in: rl, now: now) where w.percent > 0 {
                if let index = windows.firstIndex(where: { $0.label == w.label }) {
                    windows[index].splits.append(WindowSplit(label: label, percent: w.percent))
                }
            }
        }
        return windows
    }

    nonisolated private static func accountWindows(in rl: [String: Any], now: Date) -> [UsageTracker.CodexWindow] {
        var out: [UsageTracker.CodexWindow] = []
        for (key, positional) in [("primary_window", "5h"), ("secondary_window", "1w")] {
            guard let w = rl[key] as? [String: Any],
                  let pct = number(w["used_percent"]) else { continue }
            let resets: Date
            if let epoch = number(w["reset_at"]) { resets = Date(timeIntervalSince1970: epoch) }
            else if let after = number(w["reset_after_seconds"]) { resets = now.addingTimeInterval(after) }
            else { continue }
            guard resets > now else { continue }
            let label: String
            if let seconds = number(w["limit_window_seconds"]) { label = seconds <= 12 * 3600 ? "5h" : "1w" }
            else { label = positional }
            if !out.contains(where: { $0.label == label }) {
                out.append(UsageTracker.CodexWindow(label: label, percent: pct, resetsAt: resets))
            }
        }
        return out
    }

    nonisolated private static func number(_ v: Any?) -> Double? {
        (v as? Double) ?? (v as? Int).map(Double.init)
    }
}
