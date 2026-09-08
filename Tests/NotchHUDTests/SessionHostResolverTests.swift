import XCTest
@testable import NotchHUD

final class SessionHostResolverTests: XCTestCase {
    func testExactRolloutFileMapping() {
        let text = """
        p42
        n/Users/dev/.codex/sessions/2026/09/08/rollout-one.jsonl
        n/Users/dev/.codex/auth.json
        p84
        n/Users/dev/.codex/sessions/2026/09/08/rollout-two.jsonl
        """
        let result = SessionHostResolver.parseOpenFiles(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["/Users/dev/.codex/sessions/2026/09/08/rollout-one.jsonl"], 42)
        XCTAssertEqual(result["/Users/dev/.codex/sessions/2026/09/08/rollout-two.jsonl"], 84)
    }

    func testHostComesFromAncestorsNotCLIName() {
        let processes = SessionHostResolver.parseProcesses("""
        43 42 /Users/dev/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude
        42 40 codex
        40 30 -/bin/zsh
        30 20 /Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper
        20 1 /Applications/Orca.app/Contents/MacOS/Orca
        84 80 codex
        80 70 /bin/zsh
        70 1 /Applications/Ghostty.app/Contents/MacOS/ghostty
        90 1 /Applications/Visual Studio Code.app/Contents/Resources/app/bin/codex
        """)
        XCTAssertEqual(SessionHostResolver.applicationPath(for: 43, processes: processes), "/Applications/Orca.app")
        XCTAssertEqual(SessionHostResolver.applicationPath(for: 42, processes: processes), "/Applications/Orca.app")
        XCTAssertEqual(SessionHostResolver.applicationPath(for: 84, processes: processes), "/Applications/Ghostty.app")
        XCTAssertEqual(SessionHostResolver.applicationPath(for: 90, processes: processes), "/Applications/Visual Studio Code.app")
    }

    func testUnknownAndCyclicAncestryDoNotGuess() {
        let processes = SessionHostResolver.parseProcesses("42 40 codex\n40 42 /bin/zsh\n99 1 codex")
        XCTAssertNil(SessionHostResolver.applicationPath(for: 42, processes: processes))
        XCTAssertNil(SessionHostResolver.applicationPath(for: 99, processes: processes))
        XCTAssertNil(SessionHostResolver.applicationPath(for: 100, processes: processes))
    }
}
