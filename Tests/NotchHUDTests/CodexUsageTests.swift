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
