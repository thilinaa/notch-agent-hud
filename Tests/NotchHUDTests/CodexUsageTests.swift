import XCTest
@testable import NotchHUD

final class CodexUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    func testPlusPlanHasFiveHourPrimaryAndWeeklySecondary() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 7.0, "window_minutes": 300, "resets_at": now.timeIntervalSince1970 + 3600],
            "secondary": ["used_percent": 1.0, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 5 * 86400],
        ]
        let w = UsageTracker.codexWindows(from: rl, now: now)
        XCTAssertEqual(w.map { $0.label }, ["5h", "1w"])
        XCTAssertEqual(w.map { $0.percent }, [7, 1])
    }

    func testProPlanWeeklyOnlyPrimaryLandsInTheWeeklySlot() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 37.0, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 5 * 86400],
            "secondary": NSNull(),
        ]
        let w = UsageTracker.codexWindows(from: rl, now: now)
        XCTAssertEqual(w.map { $0.label }, ["1w"], "a weekly primary is not a 5-hour window")
        XCTAssertEqual(w.first?.percent, 37)
    }

    func testMissingWindowMinutesFallsBackToPosition() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 50, "resets_at": Int(now.timeIntervalSince1970) + 600],
            "secondary": ["used_percent": 20, "resets_at": Int(now.timeIntervalSince1970) + 600],
        ]
        XCTAssertEqual(UsageTracker.codexWindows(from: rl, now: now).map { $0.label }, ["5h", "1w"])
    }

    func testExpiredWindowsAreDropped() {
        let rl: [String: Any] = [
            "primary": ["used_percent": 90.0, "window_minutes": 300, "resets_at": now.timeIntervalSince1970 - 1],
        ]
        XCTAssertTrue(UsageTracker.codexWindows(from: rl, now: now).isEmpty)
    }

    func testAccountBucketWinsOverAFresherModelBucket() {
        let account: [String: Any] = ["limit_id": "codex",
            "primary": ["used_percent": 6.0, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 5 * 86400]]
        let model: [String: Any] = ["limit_id": "codex_bengalfox",
            "primary": ["used_percent": 0.0, "window_minutes": 300, "resets_at": now.timeIntervalSince1970 + 3600],
            "secondary": ["used_percent": 0.0, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 6 * 86400]]
        // The model bucket was reported more recently (first in order) but is not the account's limit.
        let w = UsageTracker.codexWindows(fromBuckets: ["codex_bengalfox": model, "codex": account],
                                          order: ["codex_bengalfox", "codex"], now: now)
        XCTAssertEqual(w.map { $0.label }, ["1w"])
        XCTAssertEqual(w.first?.percent, 6)
        XCTAssertTrue(w.first!.splits.isEmpty, "a bucket at 0% adds nothing")
    }

    func testModelBucketWithUsageBecomesASplit() {
        let account: [String: Any] = ["limit_id": "codex",
            "primary": ["used_percent": 10.0, "window_minutes": 300, "resets_at": now.timeIntervalSince1970 + 3600],
            "secondary": ["used_percent": 20.0, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 5 * 86400]]
        let model: [String: Any] = ["limit_id": "codex_bengalfox",
            "secondary": ["used_percent": 45.0, "window_minutes": 10080, "resets_at": now.timeIntervalSince1970 + 5 * 86400]]
        let w = UsageTracker.codexWindows(fromBuckets: ["codex": account, "codex_bengalfox": model],
                                          order: ["codex", "codex_bengalfox"], now: now)
        XCTAssertEqual(w.first { $0.label == "1w" }?.splits, [WindowSplit(label: "bengalfox", percent: 45)])
        XCTAssertTrue(w.first { $0.label == "5h" }!.splits.isEmpty)
    }

    func testWithoutAnAccountBucketTheFreshestReportStands() {
        let model: [String: Any] = ["limit_id": "codex_bengalfox",
            "primary": ["used_percent": 3.0, "window_minutes": 300, "resets_at": now.timeIntervalSince1970 + 3600]]
        let w = UsageTracker.codexWindows(fromBuckets: ["codex_bengalfox": model], order: ["codex_bengalfox"], now: now)
        XCTAssertEqual(w.map { $0.percent }, [3])
    }

    func testSplitWindowsShareResetAndLength() {
        var week = WindowUsage(resetsAt: now.addingTimeInterval(86400), limitHit: false, percent: 20, length: WindowUsage.oneWeek)
        week.splits = [WindowSplit(label: "Fable", percent: 58)]
        let derived = week.splitWindows
        XCTAssertEqual(derived.map { $0.label }, ["Fable"])
        XCTAssertEqual(derived.first?.window.percent, 58)
        XCTAssertEqual(derived.first?.window.resetsAt, week.resetsAt)
        XCTAssertEqual(derived.first?.window.length, WindowUsage.oneWeek)
        XCTAssertFalse(derived.first!.window.limitHit)
    }
}
