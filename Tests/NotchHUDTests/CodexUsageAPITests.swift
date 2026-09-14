import XCTest
@testable import NotchHUD

final class CodexUsageAPITests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_400_000)

    func testParsesAccountWindowsAndModelPools() {
        let obj: [String: Any] = [
            "plan_type": "prolite",
            "rate_limit": ["allowed": true, "limit_reached": false,
                           "primary_window": ["used_percent": 9, "limit_window_seconds": 604800,
                                              "reset_after_seconds": 474680, "reset_at": now.timeIntervalSince1970 + 474680],
                           "secondary_window": NSNull()],
            "additional_rate_limits": [
                ["limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
                 "rate_limit": ["primary_window": ["used_percent": 0, "limit_window_seconds": 18000, "reset_at": now.timeIntervalSince1970 + 3600],
                                "secondary_window": ["used_percent": 12, "limit_window_seconds": 604800, "reset_at": now.timeIntervalSince1970 + 400000]]],
            ],
        ]
        let w = CodexUsageAPI.parse(obj, now: now)
        XCTAssertEqual(w.map { $0.label }, ["1w"], "a weekly-only plan has no 5-hour window")
        XCTAssertEqual(w.first?.percent, 9)
        XCTAssertEqual(w.first?.splits, [WindowSplit(label: "GPT-5.3-Codex-Spark", percent: 12)], "a pool at 0% adds nothing; one with usage does")
    }

    func testPlusShapeHasBothWindows() {
        let obj: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 7.0, "limit_window_seconds": 18000, "reset_at": now.timeIntervalSince1970 + 3600],
                           "secondary_window": ["used_percent": 1.0, "limit_window_seconds": 604800, "reset_at": now.timeIntervalSince1970 + 86400]],
        ]
        XCTAssertEqual(CodexUsageAPI.parse(obj, now: now).map { $0.label }, ["5h", "1w"])
    }

    func testResetAfterSecondsStandsInForResetAt() {
        let obj: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 3, "limit_window_seconds": 18000, "reset_after_seconds": 900]]]
        let w = CodexUsageAPI.parse(obj, now: now)
        XCTAssertEqual(w.first?.resetsAt, now.addingTimeInterval(900))
    }

    func testMissingOrExpiredIsEmpty() {
        XCTAssertTrue(CodexUsageAPI.parse([:], now: now).isEmpty)
        XCTAssertTrue(CodexUsageAPI.parse(["rate_limit": ["primary_window": ["used_percent": 50, "reset_at": now.timeIntervalSince1970 - 1]]], now: now).isEmpty)
    }

    func testCredentialsComeFromAuthFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"abc","account_id":"acct"}}"#.utf8)
            .write(to: home.appendingPathComponent(".codex/auth.json"))
        let creds = try XCTUnwrap(CodexUsageAPI.credentials(home: home.path))
        XCTAssertEqual(creds.accessToken, "abc")
        XCTAssertEqual(creds.accountID, "acct")
        XCTAssertNil(CodexUsageAPI.credentials(home: "/nonexistent"))
    }
}
