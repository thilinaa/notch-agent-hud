import XCTest
@testable import NotchHUD

final class UpdaterTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Updater.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(Updater.isNewer("0.2.1", than: "0.2"))
        XCTAssertFalse(Updater.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.2.0", than: "0.2.1"))
        XCTAssertFalse(Updater.isNewer("0.2.1", than: "0.0.0-dev"), "a dev build never updates itself")
        XCTAssertFalse(Updater.isNewer("garbage", than: "0.2.0"))
    }

    func testParsesGitHubRelease() throws {
        let obj: [String: Any] = [
            "tag_name": "v0.2.1",
            "html_url": "https://github.com/thilinaa/notch-agent-hud/releases/tag/v0.2.1",
            "body": "Fixes.",
            "assets": [
                ["name": "NotchHUD-0.2.1.dmg.sha256", "browser_download_url": "https://example.com/NotchHUD-0.2.1.dmg.sha256"],
                ["name": "NotchHUD-0.2.1.dmg", "browser_download_url": "https://example.com/NotchHUD-0.2.1.dmg"],
            ],
        ]
        let r = try XCTUnwrap(Updater.parseRelease(obj))
        XCTAssertEqual(r.version, "0.2.1")
        XCTAssertEqual(r.dmgURL.lastPathComponent, "NotchHUD-0.2.1.dmg")
        XCTAssertEqual(r.checksumURL?.lastPathComponent, "NotchHUD-0.2.1.dmg.sha256")
        XCTAssertEqual(r.notes, "Fixes.")
    }

    func testReleaseWithoutDMGOrWithOddTagIsIgnored() {
        XCTAssertNil(Updater.parseRelease(["tag_name": "v0.3.0", "html_url": "https://example.com", "assets": []]))
        XCTAssertNil(Updater.parseRelease(["tag_name": "nightly", "html_url": "https://example.com",
                                           "assets": [["name": "x.dmg", "browser_download_url": "https://example.com/x.dmg"]]]))
    }

    func testPreferenceDefaultsOn() {
        XCTAssertTrue(HUDPreferences().checkForUpdates)
        XCTAssertFalse(HUDConfig.parseV2(["subscriptions": [], "preferences": ["checkForUpdates": false]]).preferences.checkForUpdates)
    }
}
