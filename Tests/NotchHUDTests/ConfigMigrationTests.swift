import XCTest
@testable import NotchHUD

final class ConfigMigrationTests: XCTestCase {
    private let home = NSHomeDirectory()

    private let v1: [String: Any] = [
        "port": 48618,
        "terminalApp": "Ghostty",
        "ownerAccounts": ["acme": "alex-acme", "alexdev": "alexdev", "alexcontract": "alexContract"],
        "pathAccounts": ["~/Personal": "alexdev", "~/Work/ACME": "alex-acme", "~/Work": "alexContract"],
        "claudeAccounts": ["alex@acme.example": "WORK", "Alex.Dev@example.com": "PERSONAL"],
    ]

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchhud-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Migration

    func testV1LabelsBecomeSubscriptionsVerbatim() {
        let cfg = HUDConfig.migrateV1(v1)
        let work = cfg.subscription(forEmail: "alex@acme.example")
        let personal = cfg.subscription(forEmail: "alex.dev@example.com")
        XCTAssertEqual(work?.label, "WORK")
        XCTAssertEqual(personal?.label, "PERSONAL")
        XCTAssertEqual(personal?.email, "alex.dev@example.com", "emails are stored lowercased")
        XCTAssertNotEqual(work?.accent, personal?.accent, "distinct default accents")
        XCTAssertTrue(cfg.subscriptions.contains { $0.provider == .codex && $0.id == Subscription.codexID })
        XCTAssertFalse(cfg.needsOnboarding)
    }

    func testV1PathRulesKeepGhAccountsAndLinkSubscriptions() {
        let cfg = HUDConfig.migrateV1(v1)
        let work = cfg.subscription(forEmail: "alex@acme.example")!
        let personal = cfg.subscription(forEmail: "alex.dev@example.com")!

        XCTAssertEqual(cfg.expectedGhAccount(forPath: home + "/Personal/x", owner: nil), "alexdev")
        XCTAssertEqual(cfg.expectedGhAccount(forPath: home + "/Work/ACME/api", owner: nil), "alex-acme")
        XCTAssertEqual(cfg.expectedGhAccount(forPath: home + "/Work/other", owner: nil), "alexContract")

        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Personal/x", owner: nil)?.id, personal.id)
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Work/ACME/api", owner: nil)?.id, work.id)
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Work/other", owner: nil)?.id, work.id)
    }

    func testV1OwnerRulesInheritSubscriptionThroughGhAccount() {
        let cfg = HUDConfig.migrateV1(v1)
        let work = cfg.subscription(forEmail: "alex@acme.example")!
        let personal = cfg.subscription(forEmail: "alex.dev@example.com")!
        XCTAssertEqual(cfg.expectedGhAccount(forPath: "/elsewhere", owner: "Acme"), "alex-acme")
        XCTAssertEqual(cfg.expectedSubscription(forPath: "/elsewhere", owner: "acme")?.id, work.id)
        XCTAssertEqual(cfg.expectedSubscription(forPath: "/elsewhere", owner: "alexdev")?.id, personal.id)
    }

    func testMigrationWithoutPersonalWordLeavesRulesUnlinkedWhenAmbiguous() {
        let obj: [String: Any] = [
            "claudeAccounts": ["a@x.io": "Acme", "b@y.io": "Home"],
            "pathAccounts": ["~/Code": "someone"],
        ]
        let cfg = HUDConfig.migrateV1(obj)
        XCTAssertEqual(cfg.subscriptions.filter { $0.provider == .claude }.count, 2)
        XCTAssertEqual(cfg.expectedGhAccount(forPath: home + "/Code/p", owner: nil), "someone")
        XCTAssertNil(cfg.expectedSubscription(forPath: home + "/Code/p", owner: nil),
                     "two arbitrary labels: the app must not guess which one a path belongs to")
        XCTAssertFalse(cfg.isCrossover(email: "a@x.io", path: home + "/Code/p"))
    }

    func testSingleAccountAbsorbsAllPathRules() {
        let obj: [String: Any] = [
            "claudeAccounts": ["solo@x.io": "Mine"],
            "pathAccounts": ["~/Code": "me", "~/Personal": "me"],
        ]
        let cfg = HUDConfig.migrateV1(obj)
        let solo = cfg.subscription(forEmail: "solo@x.io")!
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Code/p", owner: nil)?.id, solo.id)
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Personal/p", owner: nil)?.id, solo.id)
    }

    func testLoadMigratesFileInPlaceWithBackup() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: v1).write(to: url)

        let loaded = HUDConfig.load(from: url)
        XCTAssertEqual(loaded.subscriptions.filter { $0.provider == .claude }.count, 2)

        let backup = dir.appendingPathComponent("config.v1.backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(rewritten?["version"] as? Int, HUDConfig.currentVersion)
        XCTAssertNotNil(rewritten?["subscriptions"])
        XCTAssertNil(rewritten?["claudeAccounts"], "v1 keys are not carried into the v2 file")

        // Second load reads v2 directly and reproduces the same config, ids included.
        XCTAssertEqual(HUDConfig.load(from: url), loaded)
    }

    func testMissingFileYieldsDefaultsNeedingOnboarding() throws {
        let dir = try tempDir()
        let cfg = HUDConfig.load(from: dir.appendingPathComponent("config.json"))
        XCTAssertTrue(cfg.needsOnboarding)
        XCTAssertEqual(cfg.port, 48618)
        XCTAssertTrue(cfg.subscriptions.isEmpty, "nothing is pre-seeded; detection fills it in")
        XCTAssertFalse(cfg.hasCodex)
        XCTAssertEqual(cfg.codexSubscription.label, "Codex", "Codex data still has a lane to land in")
        XCTAssertTrue(cfg.rules.isEmpty)
    }

    func testV2RoundTrip() throws {
        var cfg = HUDConfig(port: 5000, terminalApp: "kitty", codexApp: "com.example.codex")
        let a = Subscription(provider: .claude, email: "A@x.io", label: "Acme", accent: .violet)
        let b = Subscription(provider: .claude, email: "b@y.io", label: "Home", accent: .teal, visible: false)
        cfg.subscriptions = [a, b]
        cfg.rules = [
            RepoRule(kind: .pathPrefix, value: "~/Work", ghAccount: "w", subscriptionID: a.id),
            RepoRule(kind: .owner, value: "MyOrg", ghAccount: "w", subscriptionID: a.id),
        ]

        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.json")
        try cfg.save(to: url)
        let loaded = HUDConfig.load(from: url)
        XCTAssertEqual(loaded, cfg)
        XCTAssertEqual(loaded.rules[1].value, "myorg", "owners are lowercased")
        XCTAssertEqual(loaded.subscription(forEmail: "a@x.io")?.label, "Acme")
        XCTAssertFalse(loaded.lane(forEmail: "b@y.io").visible)
    }

    // MARK: Resolution

    private func twoAccounts() -> (HUDConfig, Subscription, Subscription) {
        var cfg = HUDConfig()
        let a = Subscription(provider: .claude, email: "a@x.io", label: "Acme", accent: .blue)
        let b = Subscription(provider: .claude, email: "b@y.io", label: "Second personal", accent: .rose)
        cfg.subscriptions = [a, b]
        cfg.rules = [
            RepoRule(kind: .pathPrefix, value: "~/Work", ghAccount: "work-gh", subscriptionID: a.id),
            RepoRule(kind: .pathPrefix, value: "~/Work/side", ghAccount: "side-gh", subscriptionID: b.id),
            RepoRule(kind: .owner, value: "acme", ghAccount: "work-gh", subscriptionID: a.id),
            RepoRule(kind: .pathPrefix, value: "~/Scratch", ghAccount: "scratch-gh"),
        ]
        cfg.subscriptions.append(HUDConfig.defaultCodex)
        return (cfg, a, b)
    }

    func testLongestPathPrefixWinsAndOwnerBeatsPath() {
        let (cfg, a, b) = twoAccounts()
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Work/api", owner: nil)?.id, a.id)
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Work/side/app", owner: nil)?.id, b.id)
        XCTAssertEqual(cfg.expectedSubscription(forPath: home + "/Work/side/app", owner: "acme")?.id, a.id)
        XCTAssertEqual(cfg.expectedGhAccount(forPath: home + "/Work/side/app", owner: nil), "side-gh")
    }

    func testPrefixMatchesOnDirectoryBoundary() {
        let (cfg, _, _) = twoAccounts()
        XCTAssertNil(cfg.expectedSubscription(forPath: home + "/Workshop/x", owner: nil))
        XCTAssertNotNil(cfg.expectedSubscription(forPath: home + "/Work", owner: nil))
    }

    func testRuleWithoutSubscriptionStillGuardsGhButNeverWarns() {
        let (cfg, _, _) = twoAccounts()
        XCTAssertEqual(cfg.expectedGhAccount(forPath: home + "/Scratch/p", owner: nil), "scratch-gh")
        XCTAssertNil(cfg.expectedSubscription(forPath: home + "/Scratch/p", owner: nil))
        XCTAssertFalse(cfg.isCrossover(email: "a@x.io", path: home + "/Scratch/p"))
    }

    func testCrossoverIsPurelyRuleBased() {
        let (cfg, _, _) = twoAccounts()
        XCTAssertFalse(cfg.isCrossover(email: "A@X.IO", path: home + "/Work/api"))
        XCTAssertTrue(cfg.isCrossover(email: "b@y.io", path: home + "/Work/api"))
        XCTAssertTrue(cfg.isCrossover(email: "a@x.io", path: home + "/Work/side/app"))
        XCTAssertFalse(cfg.isCrossover(email: "stranger@z.io", path: home + "/Work/api"),
                       "unlabeled logins never warn")
        XCTAssertFalse(cfg.isCrossover(email: "a@x.io", path: "/nowhere"))
    }

    func testLanesForLabeledUnlabeledAndCodex() {
        let (cfg, a, _) = twoAccounts()
        XCTAssertEqual(cfg.lane(forEmail: "a@x.io").id, a.id)
        XCTAssertEqual(cfg.lane(forEmail: "a@x.io").label, "Acme")

        let stranger = cfg.lane(forEmail: "Stranger@z.io")
        XCTAssertEqual(stranger.id, "claude:stranger@z.io")
        XCTAssertEqual(stranger.label, "STRANGER")
        XCTAssertFalse(stranger.isConfigured)
        XCTAssertEqual(cfg.lane(id: stranger.id), stranger, "ad-hoc lane ids resolve back")

        XCTAssertEqual(cfg.codexLane.id, Subscription.codexID)
        XCTAssertEqual(cfg.lane(id: Lane.unknownID), Lane.unknown)
        XCTAssertEqual(cfg.label(forEmail: "a@x.io"), "Acme")
        XCTAssertEqual(cfg.label(forEmail: "nobody@q.io"), "NOBODY")
    }

    func testSessionLaneFallsBackToRepoRuleWithoutAccountStamp() {
        let (cfg, a, b) = twoAccounts()
        func session(_ tool: AgentTool, cwd: String, account: String?) -> AgentSession {
            var s = AgentSession(id: UUID().uuidString, tool: tool, cwd: cwd, state: .done, detail: nil,
                                 startedAt: Date(), lastEvent: Date())
            s.account = account
            return s
        }
        XCTAssertEqual(cfg.laneID(for: session(.claude, cwd: home + "/Work/side/x", account: "a@x.io")), a.id,
                       "the stamped account wins over the path rule")
        XCTAssertEqual(cfg.laneID(for: session(.claude, cwd: home + "/Work/side/x", account: nil)), b.id)
        XCTAssertEqual(cfg.laneID(for: session(.claude, cwd: "/nowhere", account: nil)), Lane.unknownID)
        XCTAssertEqual(cfg.laneID(for: session(.codex, cwd: home + "/Work/x", account: nil)), Subscription.codexID)
    }

    func testCeilingsRekeyFromV1Labels() {
        let (cfg, a, _) = twoAccounts()
        let rekeyed = UsageTracker.rekeyCeilings(["Acme": 700_000, "Ghost": 5, a.id: 600_000], config: cfg)
        XCTAssertEqual(rekeyed[a.id], 700_000, "label key merges into the id, keeping the larger cap")
        XCTAssertEqual(rekeyed["Ghost"], 5)
        XCTAssertNil(rekeyed["Acme"])
    }

    func testExactlyOneCodexSubscription() {
        var cfg = HUDConfig()
        cfg.subscriptions = [
            Subscription(id: "c1", provider: .codex, email: nil, label: "Codex A", accent: .graphite),
            Subscription(id: "c2", provider: .codex, email: nil, label: "Codex B", accent: .graphite),
        ]
        let fixed = cfg.deduplicatingCodex()
        XCTAssertEqual(fixed.subscriptions.filter { $0.provider == .codex }.count, 1)
        XCTAssertEqual(fixed.codexSubscription.id, "c1")
        XCTAssertFalse(HUDConfig().deduplicatingCodex().hasCodex, "dedupe never adds one")
    }
}
