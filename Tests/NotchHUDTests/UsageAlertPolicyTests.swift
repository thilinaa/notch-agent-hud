import XCTest
@testable import NotchHUD

final class UsageAlertPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lane = Lane(id: "work", label: "Work", provider: .claude, accent: .blue, visible: true, isConfigured: true)

    private func sub(fiveHour: Double?, resetsIn: TimeInterval = 3600, limit: Bool = false,
                     weekly: Double? = nil, splits: [WindowSplit] = []) -> SubscriptionUsage {
        var five: WindowUsage?
        if let fiveHour {
            five = WindowUsage(resetsAt: now.addingTimeInterval(resetsIn), limitHit: limit, percent: fiveHour)
        }
        var week: WindowUsage?
        if let weekly {
            week = WindowUsage(resetsAt: now.addingTimeInterval(86400), limitHit: false, percent: weekly,
                               length: WindowUsage.oneWeek, splits: splits)
        }
        return SubscriptionUsage(lane: lane, fiveHour: five, weekly: week)
    }

    func testThresholdFiresOnceThenLimitOnce() {
        var policy = UsageAlertPolicy()
        XCTAssertEqual(policy.evaluate([sub(fiveHour: 40)], threshold: 80, now: now), [])
        let first = policy.evaluate([sub(fiveHour: 82)], threshold: 80, now: now)
        XCTAssertEqual(first.map { $0.kind }, [.threshold(82)])
        XCTAssertEqual(first.first?.window, "5-hour")
        XCTAssertEqual(policy.evaluate([sub(fiveHour: 91)], threshold: 80, now: now), [], "one alert per window")
        XCTAssertEqual(policy.evaluate([sub(fiveHour: 100, limit: true)], threshold: 80, now: now).map { $0.kind }, [.limit])
        XCTAssertEqual(policy.evaluate([sub(fiveHour: 100, limit: true)], threshold: 80, now: now), [])
    }

    func testLimitWithoutPriorThresholdSkipsStraightToLimit() {
        var policy = UsageAlertPolicy()
        XCTAssertEqual(policy.evaluate([sub(fiveHour: 100, limit: true)], threshold: 80, now: now).map { $0.kind }, [.limit])
    }

    func testResetAnnouncedOnlyForWindowsThatRanHot() {
        var policy = UsageAlertPolicy()
        _ = policy.evaluate([sub(fiveHour: 85)], threshold: 80, now: now)
        // A new window with a later reset appears after the old one expired.
        let later = now.addingTimeInterval(3700)
        let alerts = policy.evaluate([sub(fiveHour: 3, resetsIn: 18000 - 100)], threshold: 80, now: later)
        XCTAssertEqual(alerts.map { $0.kind }, [.reset])

        var quiet = UsageAlertPolicy()
        _ = quiet.evaluate([sub(fiveHour: 20)], threshold: 80, now: now)
        XCTAssertEqual(quiet.evaluate([sub(fiveHour: 1, resetsIn: 18000)], threshold: 80, now: later), [], "a calm window resets silently")
    }

    func testVanishedHotWindowAnnouncesResetAndForgetsItself() {
        var policy = UsageAlertPolicy()
        _ = policy.evaluate([sub(fiveHour: 90)], threshold: 80, now: now)
        let later = now.addingTimeInterval(4000)
        XCTAssertEqual(policy.evaluate([sub(fiveHour: nil)], threshold: 80, now: later).map { $0.kind }, [.reset])
        XCTAssertEqual(policy.evaluate([sub(fiveHour: nil)], threshold: 80, now: later), [])
        XCTAssertTrue(policy.windows.isEmpty)
    }

    func testScopedWeeklyCapCountsTowardTheThreshold() {
        var policy = UsageAlertPolicy()
        let alerts = policy.evaluate([sub(fiveHour: 10, weekly: 30, splits: [WindowSplit(label: "Fable", percent: 84)])], threshold: 80, now: now)
        XCTAssertEqual(alerts.map { $0.window }, ["weekly"])
        XCTAssertEqual(alerts.first?.kind, .threshold(84))
    }

    func testStateRoundTripsThroughJSON() throws {
        var policy = UsageAlertPolicy()
        _ = policy.evaluate([sub(fiveHour: 85)], threshold: 80, now: now)
        let data = try JSONEncoder().encode(policy)
        var restored = try JSONDecoder().decode(UsageAlertPolicy.self, from: data)
        XCTAssertEqual(restored, policy)
        XCTAssertEqual(restored.evaluate([sub(fiveHour: 88)], threshold: 80, now: now), [], "a relaunch does not repeat the alert")
    }

    func testPreferencesDefaultsAndClamping() {
        XCTAssertTrue(HUDPreferences().usageAlerts)
        XCTAssertEqual(HUDPreferences().alertThreshold, 80)
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": [], "preferences": ["alertThreshold": 250]]).preferences.alertThreshold, 80)
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": [], "preferences": ["alertThreshold": 70, "usageAlerts": false]]).preferences.alertThreshold, 70)
        XCTAssertFalse(HUDConfig.parseV2(["subscriptions": [], "preferences": ["usageAlerts": false]]).preferences.usageAlerts)
    }
}
