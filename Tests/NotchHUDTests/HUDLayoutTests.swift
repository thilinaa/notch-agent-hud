import XCTest
@testable import NotchHUD

final class HUDLayoutTests: XCTestCase {
    func testAttentionScrollingStartsAtFour() {
        for count in 0...3 { XCTAssertFalse(HUDLayout.scrollsAttention(count: count)) }
        XCTAssertTrue(HUDLayout.scrollsAttention(count: 4))
        XCTAssertTrue(HUDLayout.scrollsAttention(count: 30))
    }

    func testFooterGetsSpaceBeforeActivity() {
        let activity = HUDLayout.activityHeight(maxBodyHeight: 800, heading: 78, footer: 265)
        XCTAssertEqual(activity + 78 + 265 + 36, 800)
        XCTAssertEqual(HUDLayout.activityHeight(maxBodyHeight: 300, heading: 78, footer: 265), 0)
    }

    func testLongRequestsCannotConsumeEntireViewport() {
        let height = HUDLayout.attentionHeight(firstThree: [300, 500, 600], activityBudget: 450, hasOtherSessions: true)
        XCTAssertLessThan(height, 450)
        XCTAssertLessThanOrEqual(height, 480)
        XCTAssertEqual(HUDLayout.attentionHeight(firstThree: [140, 140, 140], activityBudget: 900, hasOtherSessions: true), 438)
    }

    func testRulesAreOptional() {
        let config = HUDConfig()
        XCTAssertNil(config.expectedGhAccount(forPath: "/Users/new/Personal/project", owner: "someone"))
        XCTAssertNil(config.expectedGhAccount(forPath: "/Users/new/Work/project", owner: nil))
    }
}
