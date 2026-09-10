import XCTest
@testable import NotchHUD

final class ClaudeUsageAPITests: XCTestCase {
    private func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }

    func testParsesWindowsAndScopedWeeklyLimits() throws {
        let obj: [String: Any] = [
            "five_hour": ["utilization": 30.0, "resets_at": iso(3600)],
            "seven_day": ["utilization": 20, "resets_at": iso(5 * 86400)],
            "seven_day_opus": NSNull(),
            "limits": [
                ["kind": "session", "group": "session", "percent": 30, "resets_at": iso(3600)],
                ["kind": "weekly_all", "group": "weekly", "percent": 20, "resets_at": iso(5 * 86400)],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 37, "resets_at": iso(5 * 86400),
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": iso(5 * 86400),
                 "scope": ["model": ["id": "claude-sonnet-5", "display_name": NSNull()]]],
            ],
        ]
        let w = try XCTUnwrap(ClaudeUsageAPI.parse(obj))
        XCTAssertEqual(w.fiveHour?.percent, 30)
        XCTAssertEqual(w.weekly?.percent, 20)
        XCTAssertEqual(w.weeklySplits.map { $0.label }, ["Fable", "claude-sonnet-5"], "tightest first; id stands in for a missing name")
        XCTAssertEqual(w.weeklySplits.first?.percent, 37)
    }

    func testLegacyModelKeysBecomeSplitsWhenNoLimitsArray() throws {
        let obj: [String: Any] = [
            "five_hour": ["utilization": 5, "resets_at": iso(3600)],
            "seven_day": ["utilization": 40, "resets_at": iso(86400)],
            "seven_day_opus": ["utilization": 55, "resets_at": iso(86400)],
            "seven_day_sonnet": ["utilization": 10, "resets_at": iso(86400)],
        ]
        let w = try XCTUnwrap(ClaudeUsageAPI.parse(obj))
        XCTAssertEqual(w.weeklySplits.map { $0.label }, ["Opus", "Sonnet"])
    }

    func testExpiredAndEmptyResponsesAreIgnored() {
        XCTAssertNil(ClaudeUsageAPI.parse(["five_hour": ["utilization": 30, "resets_at": iso(-60)]]))
        XCTAssertNil(ClaudeUsageAPI.parse([:]))
        XCTAssertNil(ClaudeUsageAPI.parse(["five_hour": ["utilization": NSNull(), "resets_at": iso(60)]]))
    }

    func testTightestReadingPrefersABindingSplit() {
        var week = WindowUsage(resetsAt: Date().addingTimeInterval(86400), limitHit: false, percent: 20, length: WindowUsage.oneWeek)
        XCTAssertEqual(week.tightestPercent, 20)
        week.splits = [WindowSplit(label: "Fable", percent: 37)]
        XCTAssertEqual(week.tightestPercent, 37)
        XCTAssertEqual(week.tightestValueText(.used), "37%")
        XCTAssertEqual(week.tightestValueText(.remaining), "63% left")
        XCTAssertEqual(week.valueText(.used), "20%", "the overall figure still reads as itself")
        XCTAssertEqual(week.splits[0].valueText(.remaining), "Fable 63% left")
    }
}
