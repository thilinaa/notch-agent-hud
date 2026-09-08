import XCTest
@testable import NotchHUD

@MainActor
final class ConfigStoreTests: XCTestCase {
    private func freshStore() throws -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchhud-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        return (ConfigStore(url: url, watchFile: false), url)
    }

    func testAddNamesLoginWithDistinctAccentsAndKeepsCodexLast() throws {
        let (store, _) = try freshStore()
        XCTAssertTrue(store.config.needsOnboarding)
        store.config.subscriptions.append(HUDConfig.defaultCodex)
        let a = store.addClaudeAccount(email: " Me@Company.io ")
        let b = store.addClaudeAccount(email: "me@gmail.com", label: "Home")
        XCTAssertEqual(a.email, "me@company.io")
        XCTAssertEqual(a.label, "Me", "default label is the email's local part")
        XCTAssertEqual(b.label, "Home")
        XCTAssertNotEqual(a.accent, b.accent)
        XCTAssertEqual(store.config.subscriptions.last?.provider, .codex)
        XCTAssertTrue(store.config.needsOnboarding, "naming accounts is not the same as finishing setup")
        XCTAssertEqual(store.addClaudeAccount(email: "ME@company.io").id, a.id, "re-adding returns the existing entry")
        XCTAssertEqual(store.claudeSubscriptions.count, 2)
    }

    func testRemoveUnlinksRulesButKeepsGhAccounts() throws {
        let (store, _) = try freshStore()
        let a = store.addClaudeAccount(email: "a@x.io")
        store.config.rules = [RepoRule(kind: .pathPrefix, value: "~/Work", ghAccount: "gh-a", subscriptionID: a.id)]
        store.remove(a.id)
        XCTAssertTrue(store.claudeSubscriptions.isEmpty)
        XCTAssertNil(store.config.rules[0].subscriptionID)
        XCTAssertEqual(store.config.rules[0].ghAccount, "gh-a")
    }

    func testCodexCannotBeRemovedButCanBeRenamedAndHidden() throws {
        let (store, _) = try freshStore()
        store.config.subscriptions.append(HUDConfig.defaultCodex)
        let codex = store.config.codexSubscription
        store.remove(codex.id)
        XCTAssertEqual(store.config.codexSubscription.id, codex.id)
        store.update(codex.id) { $0.label = "OpenAI"; $0.visible = false }
        XCTAssertEqual(store.config.codexSubscription.label, "OpenAI")
        XCTAssertFalse(store.config.codexLane.visible)
    }

    func testEditsPersistToDisk() async throws {
        let (store, url) = try freshStore()
        store.addClaudeAccount(email: "a@x.io", label: "Acme")
        store.saveNow()
        let reloaded = HUDConfig.load(from: url)
        XCTAssertEqual(reloaded.subscription(forEmail: "a@x.io")?.label, "Acme")
        XCTAssertEqual(reloaded, store.config)

        // Debounced save lands without an explicit call.
        store.update(store.claudeSubscriptions[0].id) { $0.label = "Renamed" }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(HUDConfig.load(from: url).subscription(forEmail: "a@x.io")?.label, "Renamed")
    }

    func testFirstLoadAdoptsActiveClaudeLoginAndDetectedCodexOnly() throws {
        let (store, _) = try freshStore()
        store.adoptDetectedLogins(sessions: [], activeClaudeEmail: nil, codexPresent: false)
        XCTAssertTrue(store.config.subscriptions.isEmpty, "nothing detected, nothing invented")

        store.adoptDetectedLogins(sessions: [], activeClaudeEmail: "Me@Company.io", codexPresent: false)
        XCTAssertEqual(store.claudeSubscriptions.map { $0.email }, ["me@company.io"])
        XCTAssertEqual(store.claudeSubscriptions[0].label, "Me", "a neutral label, never WORK or PERSONAL")
        XCTAssertFalse(store.config.hasCodex)

        // A second login is never adopted silently; the user names it in Settings.
        store.adoptDetectedLogins(sessions: [], activeClaudeEmail: "other@x.io", codexPresent: false)
        XCTAssertEqual(store.claudeSubscriptions.count, 1)

        var codexSession = AgentSession(id: "codex-1", tool: .codex, cwd: "/p", state: .done, detail: nil,
                                        startedAt: Date(), lastEvent: Date())
        codexSession.account = "me@openai.io"
        store.adoptDetectedLogins(sessions: [codexSession], activeClaudeEmail: "other@x.io", codexPresent: true)
        XCTAssertTrue(store.config.hasCodex)
        XCTAssertEqual(store.config.codexSubscription.email, "me@openai.io")
        XCTAssertEqual(store.config.codexSubscription.label, "Codex")
    }

    func testDetectionListsUnnamedLoginsActiveFirst() {
        func session(_ tool: AgentTool, account: String?, age: TimeInterval) -> AgentSession {
            var s = AgentSession(id: UUID().uuidString, tool: tool, cwd: "/p", state: .done, detail: nil,
                                 startedAt: Date().addingTimeInterval(-age), lastEvent: Date().addingTimeInterval(-age))
            s.account = account
            return s
        }
        let sessions = [
            session(.claude, account: "b@y.io", age: 10),
            session(.claude, account: "B@y.io", age: 20),
            session(.claude, account: "a@x.io", age: 30),
            session(.claude, account: nil, age: 40),
            session(.codex, account: "old@codex.io", age: 500),
            session(.codex, account: "new@codex.io", age: 5),
        ]
        let logins = AccountDetection.claudeLogins(sessions: sessions)
        let emails = logins.map { $0.email }
        XCTAssertTrue(emails.contains("b@y.io") && emails.contains("a@x.io"))
        XCTAssertEqual(logins.first { $0.email == "b@y.io" }?.sessions, 2)
        XCTAssertEqual(AccountDetection.codexEmail(sessions: sessions), "new@codex.io")
    }
}
