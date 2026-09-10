import XCTest
@testable import NotchHUD

final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(usedPercent: Double, elapsed: Double, length: TimeInterval = WindowUsage.fiveHours) -> WindowUsage {
        WindowUsage(resetsAt: now.addingTimeInterval(length * (1 - elapsed)), limitHit: false,
                    percent: usedPercent, length: length)
    }

    func testElapsedFractionRunsFromStartToReset() {
        XCTAssertEqual(window(usedPercent: 0, elapsed: 0.25).elapsedFraction(at: now), 0.25, accuracy: 1e-9)
        XCTAssertEqual(window(usedPercent: 0, elapsed: 0.5, length: WindowUsage.oneWeek).elapsedFraction(at: now), 0.5, accuracy: 1e-9)
        // A reset in the past clamps to 1, a future start (clock skew) to 0.
        XCTAssertEqual(WindowUsage(resetsAt: now.addingTimeInterval(-60), limitHit: false).elapsedFraction(at: now), 1)
        XCTAssertEqual(WindowUsage(resetsAt: now.addingTimeInterval(WindowUsage.fiveHours + 60), limitHit: false).elapsedFraction(at: now), 0)
    }

    func testOnPaceWhenSpendingTrailsTime() {
        guard case .onPace(let spare) = window(usedPercent: 25, elapsed: 0.5).pace(at: now) else {
            return XCTFail("half the window gone, a quarter spent: on pace")
        }
        XCTAssertEqual(spare, 0.5, accuracy: 1e-9)
    }

    func testAheadNamesTheMomentQuotaRunsOut() {
        // Half the window gone, 75% spent: at that rate the rest lasts a third as long again.
        guard case .ahead(let limitAt) = window(usedPercent: 75, elapsed: 0.5).pace(at: now) else {
            return XCTFail("spending ahead of time is ahead of pace")
        }
        let elapsedTime = WindowUsage.fiveHours * 0.5
        XCTAssertEqual(limitAt.timeIntervalSince(now), elapsedTime * (0.25 / 0.75), accuracy: 1)
    }

    func testBarelyAheadCountsAsOnPace() {
        // 52% spent at half time would run out 12 minutes before the reset: too close to call.
        guard case .onPace(let spare) = window(usedPercent: 52, elapsed: 0.5).pace(at: now) else {
            return XCTFail("a limit inside the last twentieth of the window is not a warning")
        }
        XCTAssertLessThan(spare, 0)
    }

    func testPaceStaysQuietEarlyAndWithoutAPercent() {
        XCTAssertEqual(window(usedPercent: 5, elapsed: 0.05).pace(at: now), .unknown, "the first tenth is too noisy to project")
        XCTAssertEqual(WindowUsage(resetsAt: now.addingTimeInterval(3600), limitHit: false, tokens: 120_000).pace(at: now), .unknown)
        XCTAssertEqual(WindowUsage(resetsAt: now.addingTimeInterval(3600), limitHit: true, percent: 100).pace(at: now), .unknown)
        XCTAssertEqual(window(usedPercent: 0, elapsed: 0.5).pace(at: now), .unknown)
    }
}
