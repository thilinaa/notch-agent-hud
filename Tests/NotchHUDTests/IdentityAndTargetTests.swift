import XCTest
@testable import NotchHUD

final class IdentityAndTargetTests: XCTestCase {
    func testOnlyDirectGithubDefaultIsSelected() {
        let yaml = """
        example.org:
            user: enterprise-user
        github.com:
            users:
                nested-account:
                    user: not-the-default
                another-account:
            user: 'selected-account'
        """
        XCTAssertEqual(IdentityGuard.parseDefaultAccount(yaml), "selected-account")
        XCTAssertNil(IdentityGuard.parseDefaultAccount("github.com:\n    users:\n        saved-user:\n            user: saved-user"))
        XCTAssertEqual(IdentityGuard.parseDefaultAccount("github.com:\n  user: alice\n  users:\n    bob:"), "alice")
    }

    func testTerminalHandleIsReadOnlyFromEnvironment() {
        let handle = "term_60263662-888b-4bc3-bead-a8eca779484a"
        var bytes = Data([2, 0, 0, 0])
        bytes.append(Data("/bin/codex\0\0codex\0ORCA_TERMINAL_HANDLE=bad-argument\0SECRET=ignored\0ORCA_TERMINAL_HANDLE=\(handle)\0".utf8))
        XCTAssertEqual(SessionHostResolver.parseOrcaTerminalHandle(bytes), handle)
    }

    func testInvalidProcessDataCannotBecomeFocusTarget() {
        XCTAssertNil(SessionHostResolver.parseOrcaTerminalHandle(Data()))
        var bytes = Data([1, 0, 0, 0])
        bytes.append(Data("/bin/codex\0codex\0ORCA_TERMINAL_HANDLE=term_not-a-uuid\0".utf8))
        XCTAssertNil(SessionHostResolver.parseOrcaTerminalHandle(bytes))
    }

    func testScriptParametersRemainLiteralData() {
        XCTAssertEqual(NativeSessionFocus.appleScriptLiteral("a\"\\b\nc"), "\"a\\\"\\\\b\\nc\"")
    }
}
