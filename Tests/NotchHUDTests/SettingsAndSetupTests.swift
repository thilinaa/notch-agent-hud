import XCTest
@testable import NotchHUD

final class SettingsAndSetupTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchhud-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Preferences

    func testPreferencesRoundTripAndDefaultWhenOmitted() throws {
        var cfg = HUDConfig()
        cfg.preferences.density = .compact
        cfg.preferences.appearance = .dark
        cfg.preferences.accent = .rose
        cfg.preferences.usageOnly = true
        cfg.preferences.attentionBreaksThrough = false
        cfg.preferences.onboardingCompleted = true

        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.json")
        try cfg.save(to: url)
        XCTAssertEqual(HUDConfig.load(from: url), cfg)

        // A hand-edited file may omit any preference key, or the whole block.
        let partial: [String: Any] = ["subscriptions": [], "preferences": ["density": "compact"]]
        let loaded = HUDConfig.parseV2(partial)
        XCTAssertEqual(loaded.preferences.density, .compact)
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": [], "preferences": ["density": "minimal"]]).preferences.density, .minimal)
        XCTAssertEqual(loaded.preferences.appearance, .system)
        XCTAssertTrue(loaded.preferences.attentionBreaksThrough)
        XCTAssertFalse(loaded.preferences.onboardingCompleted)
        XCTAssertTrue(loaded.needsOnboarding)
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": []]).preferences, HUDPreferences())
        XCTAssertEqual(HUDPreferences().density, .minimal, "one line per session is the default")
        XCTAssertFalse(HUDPreferences().openOnHover, "click-to-open is the default")
        XCTAssertTrue(HUDConfig.parseV2(["subscriptions": [], "preferences": ["openOnHover": true]]).preferences.openOnHover)
        XCTAssertEqual(HUDPreferences().usageValue, .used, "spent quota is the default reading")
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": [], "preferences": ["usageValue": "remaining"]]).preferences.usageValue, .remaining)
        XCTAssertEqual(HUDPreferences().usageMeter, .bars)
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": [], "preferences": ["usageMeter": "rings"]]).preferences.usageMeter, .rings)
        XCTAssertFalse(HUDPreferences().pillShowsUsage)
        XCTAssertTrue(HUDConfig.parseV2(["subscriptions": [], "preferences": ["pillShowsUsage": true]]).preferences.pillShowsUsage)

        // A v2 file written before preferences existed, with named accounts: no setup nag.
        let early: [String: Any] = ["subscriptions": [[
            "id": "x", "provider": "claude", "email": "a@x.io", "label": "Mine", "accent": "blue", "visible": true,
        ]]]
        XCTAssertFalse(HUDConfig.parseV2(early).needsOnboarding)
    }

    func testMigratedV1UsersSkipOnboarding() {
        let cfg = HUDConfig.migrateV1(["claudeAccounts": ["a@x.io": "Mine"]])
        XCTAssertFalse(cfg.needsOnboarding)
        XCTAssertTrue(HUDConfig().needsOnboarding)
    }

    // MARK: Hooks

    func testHookMergeAddsRelayOncePerEventAndKeepsOtherHooks() {
        let relay = "/Users/me/.notchhud/notify.sh"
        let other: [String: Any] = ["hooks": [["type": "command", "command": "/usr/local/bin/orca-hook"]]]
        let stale: [String: Any] = ["hooks": [["type": "command", "command": "/Users/old/.notchhud/notify.sh"]]]
        let inline: [String: Any] = ["hooks": [["type": "command", "command": "curl -s -X POST http://127.0.0.1:48618/event"]]]
        let unrelated: [String: Any] = ["hooks": [["type": "command", "command": "/opt/notchhud-fan-club/hook.sh"]]]
        let settings: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "SessionStart": [other, stale, inline, unrelated],
                "PreToolUse": [other],
            ],
        ]
        let merged = HookInstaller.merge(settings: settings, relayPath: relay)
        XCTAssertEqual(merged["theme"] as? String, "dark", "unrelated keys survive")
        let hooks = merged["hooks"] as! [String: Any]
        for event in HookInstaller.events {
            let entries = hooks[event] as! [[String: Any]]
            let relays = entries.filter { HookInstaller.isRelay($0, relayPath: relay) }
            XCTAssertEqual(relays.count, 1, "\(event) carries exactly one relay entry")
            XCTAssertEqual(((relays[0]["hooks"] as! [[String: Any]])[0]["command"] as? String), relay)
        }
        let start = hooks["SessionStart"] as! [[String: Any]]
        XCTAssertEqual(start.count, 3, "foreign hooks stay (even one merely mentioning notchhud); stale relay forms are replaced")
        XCTAssertEqual((hooks["PreToolUse"] as! [[String: Any]]).count, 1, "events we don't use are untouched")

        // Merging twice is idempotent.
        let twice = HookInstaller.merge(settings: merged, relayPath: relay)
        XCTAssertEqual((twice["hooks"] as! [String: Any]).count, (merged["hooks"] as! [String: Any]).count)
        XCTAssertEqual(((twice["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 1)
    }

    func testHookInstallWritesRelayAndSettingsWithBackup() throws {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("settings.json").path
        let relay = dir.appendingPathComponent("notify.sh").path
        try Data("{\"permissions\":{\"allow\":[]}}".utf8).write(to: URL(fileURLWithPath: settings))

        XCTAssertEqual(HookInstaller.status(settings: settings, relay: relay), .notInstalled)
        try HookInstaller.install(port: 50000, settings: settings, relay: relay)
        XCTAssertEqual(HookInstaller.status(settings: settings, relay: relay), .installed)

        let script = try String(contentsOfFile: relay, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("127.0.0.1:50000/event"))
        let perms = try FileManager.default.attributesOfItem(atPath: relay)[.posixPermissions] as? Int
        XCTAssertEqual((perms ?? 0) & 0o111, 0o111, "relay is executable")

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as! [String: Any]
        XCTAssertNotNil(written["permissions"], "existing settings survive")
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("settings.json.bak.") }
        XCTAssertEqual(backups.count, 1)

        // Partial: drop one event by hand and the status says which.
        var edited = written
        var hooks = edited["hooks"] as! [String: Any]
        hooks["Stop"] = nil
        edited["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: edited).write(to: URL(fileURLWithPath: settings))
        XCTAssertEqual(HookInstaller.status(settings: settings, relay: relay), .partial(missing: ["Stop"]))
    }

    func testHookInstallRefusesToClobberInvalidSettings() throws {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("settings.json").path
        let relay = dir.appendingPathComponent("notify.sh").path
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertThrowsError(try HookInstaller.install(port: 1, settings: settings, relay: relay))
        XCTAssertEqual(try String(contentsOfFile: settings, encoding: .utf8), "{ not json", "file left as it was")
    }

    func testHookInstallCreatesSettingsWhenMissing() throws {
        let dir = try tempDir()
        let settings = dir.appendingPathComponent("claude/settings.json").path
        let relay = dir.appendingPathComponent("notify.sh").path
        try HookInstaller.install(port: 48618, settings: settings, relay: relay)
        XCTAssertEqual(HookInstaller.status(settings: settings, relay: relay), .installed)
    }

    // MARK: gh accounts

    func testAllGhAccountsAreListedDefaultFirst() {
        let yaml = """
        github.com:
            users:
                alexContract:
                    git_protocol: https
                alexdev:
                alex-acme:
            user: alex-acme
        example.org:
            users:
                other:
        """
        XCTAssertEqual(IdentityGuard.parseAllAccounts(yaml), ["alex-acme", "alexContract", "alexdev"])
        XCTAssertEqual(IdentityGuard.parseAllAccounts("github.com:\n    user: solo\n"), [])
    }

    // MARK: Rule suggestions

    func testRuleSuggestionsUseTopTwoPathComponentsMinusExisting() {
        func session(_ cwd: String) -> AgentSession {
            AgentSession(id: UUID().uuidString, tool: .claude, cwd: cwd, state: .done, detail: nil,
                         startedAt: Date(), lastEvent: Date())
        }
        let home = "/Users/me"
        let sessions = [
            session(home + "/Work/Acme/api"), session(home + "/Work/Acme/web"), session(home + "/Work/Side/x"),
            session(home + "/Personal/hud"), session("/tmp/scratch"),
            session(home + "/Library/Application Support/x"), session(home + "/.codex/tmp/y"),
        ]
        let rules = [RepoRule(kind: .pathPrefix, value: "~/Work")]
        let suggested = RuleSuggestions.pathPrefixes(sessions: sessions, rules: rules, home: home)
        XCTAssertEqual(suggested.first, "~/Work/Acme")
        XCTAssertTrue(suggested.contains("~/Personal"))
        XCTAssertFalse(suggested.contains("~/Work"), "already a rule")
        XCTAssertFalse(suggested.contains { $0.hasPrefix("/tmp") })
        XCTAssertFalse(suggested.contains { $0.hasPrefix("~/Library") || $0.hasPrefix("~/.") }, "system folders are noise")
    }
}

@MainActor
final class ConfigStoreRulesTests: XCTestCase {
    private func freshStore() throws -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notchhud-rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        return (ConfigStore(url: url, watchFile: false), url)
    }

    func testRuleCrudNormalises() throws {
        let (store, _) = try freshStore()
        let a = store.addClaudeAccount(email: "a@x.io")
        let rule = store.addRule(kind: .owner, value: "MyOrg", ghAccount: "gh")
        XCTAssertEqual(store.config.rules[0].value, "myorg")
        store.updateRule(rule.id) { $0.subscriptionID = a.id; $0.ghAccount = "" }
        XCTAssertEqual(store.config.rules[0].subscriptionID, a.id)
        XCTAssertNil(store.config.rules[0].ghAccount, "empty picker choice clears the field")
        store.removeRule(rule.id)
        XCTAssertTrue(store.config.rules.isEmpty)
    }

    func testPreferencesUpdateAndExternalEditReload() throws {
        let (store, url) = try freshStore()
        store.updatePreferences { $0.density = .compact }
        store.saveNow()
        XCTAssertEqual(HUDConfig.load(from: url).preferences.density, .compact)

        // Someone edits the file in a text editor.
        var external = HUDConfig.load(from: url)
        external.preferences.usageOnly = true
        external.subscriptions.append(Subscription(provider: .claude, email: "edited@x.io", label: "Edited", accent: .teal))
        try external.save(to: url)
        // Make sure the mtime differs even on coarse filesystems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        store.reloadIfChangedOnDisk()
        XCTAssertTrue(store.config.preferences.usageOnly)
        XCTAssertEqual(store.config.subscription(forEmail: "edited@x.io")?.label, "Edited")

        // Our own save is not mistaken for an external change.
        store.updatePreferences { $0.appearance = .light }
        store.saveNow()
        store.reloadIfChangedOnDisk()
        XCTAssertEqual(store.config.preferences.appearance, .light)
    }
}
