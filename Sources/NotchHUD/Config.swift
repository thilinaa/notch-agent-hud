import Foundation

// MARK: - Subscriptions and repo rules
//
// A subscription is a login the user owns (a Claude account, or Codex), named
// in the user's own words. Nothing in the app assumes what a label means:
// "work"/"personal" semantics only exist as repo rules the user writes.

enum SubscriptionProvider: String, Codable {
    case claude
    case codex
}

/// Limited preset accents so lanes stay distinguishable without a free picker.
enum SubscriptionAccent: String, Codable, CaseIterable {
    case blue, violet, teal, green, amber, rose, graphite

    /// Round-robin default for newly created subscriptions.
    static func preset(_ index: Int) -> SubscriptionAccent {
        let cycle: [SubscriptionAccent] = [.blue, .violet, .teal, .green, .amber, .rose]
        return cycle[((index % cycle.count) + cycle.count) % cycle.count]
    }
}

struct Subscription: Codable, Identifiable, Equatable {
    var id: String
    var provider: SubscriptionProvider
    /// Login email, lowercased. Codex may not have one until its auth is read.
    var email: String?
    /// The user's label — free text, no reserved values.
    var label: String
    var accent: SubscriptionAccent
    var visible: Bool

    init(id: String = UUID().uuidString, provider: SubscriptionProvider, email: String?,
         label: String, accent: SubscriptionAccent, visible: Bool = true) {
        self.id = id
        self.provider = provider
        self.email = email?.lowercased()
        self.label = label
        self.accent = accent
        self.visible = visible
    }

    /// The single Codex entry every config carries.
    static let codexID = "codex"
}

/// Where a subscription (and a `gh` account) is expected to be used.
struct RepoRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// `value` is a directory prefix, `~` allowed. Longest match wins.
        case pathPrefix
        /// `value` is a lowercased GitHub owner (org or user). Beats path rules.
        case owner
    }
    var id: String
    var kind: Kind
    var value: String
    /// Expected `gh auth` account for the identity guard.
    var ghAccount: String?
    /// Expected subscription for the crossover warning.
    var subscriptionID: String?

    init(id: String = UUID().uuidString, kind: Kind, value: String,
         ghAccount: String? = nil, subscriptionID: String? = nil) {
        self.id = id
        self.kind = kind
        self.value = kind == .owner ? value.lowercased() : value
        self.ghAccount = ghAccount
        self.subscriptionID = subscriptionID
    }
}

/// Display identity of a usage/recents lane. Configured subscriptions are
/// lanes; so is any login seen in the wild that the user has not named yet.
struct Lane: Hashable {
    let id: String
    let label: String
    let provider: SubscriptionProvider
    let accent: SubscriptionAccent
    let visible: Bool
    /// False for ad-hoc lanes built from an unlabeled email.
    let isConfigured: Bool

    static let unlabeledPrefix = "claude:"
    static let unknownID = "claude:unknown"

    static func unlabeled(email: String) -> Lane {
        let local = String(email.split(separator: "@").first ?? "").uppercased()
        return Lane(id: unlabeledPrefix + email.lowercased(),
                    label: local.isEmpty ? "CLAUDE" : local,
                    provider: .claude, accent: .graphite, visible: true, isConfigured: false)
    }

    static let unknown = Lane(id: unknownID, label: "CLAUDE", provider: .claude,
                              accent: .graphite, visible: true, isConfigured: false)
}

// MARK: - Preferences

enum HUDDensity: String, Codable, CaseIterable {
    case cozy, compact
    /// One line per session, so long lists fit.
    case minimal
}

enum HUDAppearance: String, Codable, CaseIterable {
    case system, light, dark
}

/// Pure UI preferences; every field has a default so a hand-edited file may
/// omit any of them.
struct HUDPreferences: Codable, Equatable {
    var density: HUDDensity = .cozy
    var appearance: HUDAppearance = .system
    /// Accent for the app's own status color (working indicator, controls).
    var accent: SubscriptionAccent = .blue
    /// Show only usage and account health; sessions keep being tracked.
    var usageOnly = false
    /// In usage-only mode, sessions that need you still surface on the pill.
    var attentionBreaksThrough = true
    var onboardingCompleted = false
    /// Read the active login's OAuth token from the Keychain to fetch exact
    /// usage. Off means estimates only and no Keychain access at all.
    var useUsageAPI = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case density, appearance, accent, usageOnly, attentionBreaksThrough, onboardingCompleted, useUsageAPI
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        density = try c.decodeIfPresent(HUDDensity.self, forKey: .density) ?? .cozy
        appearance = try c.decodeIfPresent(HUDAppearance.self, forKey: .appearance) ?? .system
        accent = try c.decodeIfPresent(SubscriptionAccent.self, forKey: .accent) ?? .blue
        usageOnly = try c.decodeIfPresent(Bool.self, forKey: .usageOnly) ?? false
        attentionBreaksThrough = try c.decodeIfPresent(Bool.self, forKey: .attentionBreaksThrough) ?? true
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        useUsageAPI = try c.decodeIfPresent(Bool.self, forKey: .useUsageAPI) ?? true
    }
}

// MARK: - Config

struct HUDConfig: Equatable {
    static let currentVersion = 2

    var port: UInt16 = 48618
    var terminalApp = "Terminal"
    /// Bundle id of the Codex desktop app (ChatGPT.app ships it).
    var codexApp = "com.openai.codex"
    var subscriptions: [Subscription] = []
    var rules: [RepoRule] = []
    var preferences = HUDPreferences()

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.notchhud/config.json")
    }

    /// True until the setup flow has been completed (or a v1 config migrated,
    /// since that user already set things up by hand).
    var needsOnboarding: Bool { !preferences.onboardingCompleted }

    /// Codex is only listed once it has been detected on this Mac.
    var hasCodex: Bool {
        subscriptions.contains { $0.provider == .codex }
    }

    // MARK: Loading, migration, saving

    /// True when a file exists at `url` but is not JSON we can read. Callers
    /// use it to avoid overwriting a hand-edited file that is mid-save or broken.
    static func isUnreadable(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) == nil
    }

    /// Reads the config, migrating a v1 file (`claudeAccounts` / `pathAccounts`
    /// / `ownerAccounts`) in place — the original is kept next to it as
    /// `config.v1.backup.json`. A missing or unreadable file yields defaults.
    static func load(from url: URL = defaultURL) -> HUDConfig {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HUDConfig()
        }
        if obj["subscriptions"] != nil {
            return parseV2(obj)
        }
        let migrated = migrateV1(obj)
        let backup = url.deletingLastPathComponent().appendingPathComponent("config.v1.backup.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? data.write(to: backup)
        }
        try? migrated.save(to: url)
        return migrated
    }

    /// Fields shared by both versions.
    private static func parseCommon(_ obj: [String: Any], into cfg: inout HUDConfig) {
        if let p = obj["port"] as? Int, p > 0, p < 65536 { cfg.port = UInt16(p) }
        if let t = obj["terminalApp"] as? String, !t.isEmpty { cfg.terminalApp = t }
        if let a = obj["codexApp"] as? String, !a.isEmpty { cfg.codexApp = a }
    }

    static func parseV2(_ obj: [String: Any]) -> HUDConfig {
        var cfg = HUDConfig()
        parseCommon(obj, into: &cfg)
        let decoder = JSONDecoder()
        if let raw = obj["subscriptions"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let subs = try? decoder.decode([Subscription].self, from: data) {
            cfg.subscriptions = subs.map {
                var s = $0
                s.email = s.email?.lowercased()
                return s
            }
        }
        if let raw = obj["rules"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let rules = try? decoder.decode([RepoRule].self, from: data) {
            cfg.rules = rules
        }
        if let raw = obj["preferences"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let prefs = try? decoder.decode(HUDPreferences.self, from: data) {
            cfg.preferences = prefs
        } else if cfg.subscriptions.contains(where: { $0.provider == .claude }) {
            // A v2 file from before preferences existed: its owner already named
            // their accounts, so setup would only be in the way.
            cfg.preferences.onboardingCompleted = true
        }
        return cfg.deduplicatingCodex()
    }

    /// v1 → v2. Labels carry over verbatim, and Codex is kept because v1
    /// always showed its lane. Repo rules are linked to a
    /// subscription using the only semantics v1 had: a prefix or label
    /// mentioning "personal" pairs with the personal-labeled account, and a
    /// single remaining account absorbs everything else. Owner rules inherit
    /// the subscription of the path rule that shares their `gh` account.
    static func migrateV1(_ obj: [String: Any]) -> HUDConfig {
        var cfg = HUDConfig()
        parseCommon(obj, into: &cfg)

        let accounts = (obj["claudeAccounts"] as? [String: String]) ?? [:]
        for (index, (email, label)) in accounts.sorted(by: { $0.key < $1.key }).enumerated() {
            cfg.subscriptions.append(Subscription(provider: .claude, email: email, label: label,
                                                  accent: SubscriptionAccent.preset(index)))
        }
        cfg.subscriptions.append(Self.defaultCodex)
        // A v1 user configured everything by hand; don't run setup at them.
        cfg.preferences.onboardingCompleted = true

        func mentionsPersonal(_ s: String) -> Bool { s.lowercased().contains("personal") }
        let claude = cfg.subscriptions.filter { $0.provider == .claude }
        let personal = claude.first { mentionsPersonal($0.label) }
        let others = claude.filter { $0.id != personal?.id }

        let paths = (obj["pathAccounts"] as? [String: String]) ?? [:]
        for (prefix, gh) in paths.sorted(by: { $0.key < $1.key }) {
            let sub: Subscription?
            if claude.count == 1 { sub = claude.first }
            else if mentionsPersonal(prefix) { sub = personal }
            else if others.count == 1 { sub = others.first }
            else { sub = nil }
            cfg.rules.append(RepoRule(kind: .pathPrefix, value: prefix, ghAccount: gh, subscriptionID: sub?.id))
        }

        let owners = (obj["ownerAccounts"] as? [String: String]) ?? [:]
        for (owner, gh) in owners.sorted(by: { $0.key < $1.key }) {
            let inherited = cfg.rules.first { $0.kind == .pathPrefix && $0.ghAccount == gh && $0.subscriptionID != nil }
            cfg.rules.append(RepoRule(kind: .owner, value: owner, ghAccount: gh, subscriptionID: inherited?.subscriptionID))
        }
        return cfg
    }

    /// The Codex entry as first created, before the user renames it.
    static var defaultCodex: Subscription {
        Subscription(id: Subscription.codexID, provider: .codex, email: nil, label: "Codex", accent: .graphite)
    }

    /// At most one Codex subscription; a hand-edited file with two keeps the first.
    func deduplicatingCodex() -> HUDConfig {
        var cfg = self
        var seen = false
        cfg.subscriptions.removeAll {
            guard $0.provider == .codex else { return false }
            defer { seen = true }
            return seen
        }
        return cfg
    }

    private struct FileShape: Codable {
        var version: Int
        var port: Int
        var terminalApp: String
        var codexApp: String
        var subscriptions: [Subscription]
        var rules: [RepoRule]
        var preferences: HUDPreferences
    }

    func save(to url: URL = defaultURL) throws {
        let shape = FileShape(version: Self.currentVersion, port: Int(port), terminalApp: terminalApp,
                              codexApp: codexApp, subscriptions: subscriptions, rules: rules,
                              preferences: preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(shape)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Subscriptions

    func subscription(id: String) -> Subscription? {
        subscriptions.first { $0.id == id }
    }

    func subscription(forEmail email: String) -> Subscription? {
        let key = email.lowercased()
        return subscriptions.first { $0.provider == .claude && $0.email == key }
    }

    /// The configured Codex entry, or the default one when Codex has not been
    /// detected yet — so Codex data always has a lane to land in.
    var codexSubscription: Subscription {
        subscriptions.first { $0.provider == .codex } ?? Self.defaultCodex
    }

    /// Display label for a login email: the user's label, else the local part.
    func label(forEmail email: String) -> String {
        subscription(forEmail: email)?.label ?? Lane.unlabeled(email: email).label
    }

    // MARK: Lanes

    func lane(for sub: Subscription) -> Lane {
        Lane(id: sub.id, label: sub.label, provider: sub.provider, accent: sub.accent,
             visible: sub.visible, isConfigured: true)
    }

    func lane(forEmail email: String) -> Lane {
        subscription(forEmail: email).map(lane(for:)) ?? .unlabeled(email: email)
    }

    var codexLane: Lane { lane(for: codexSubscription) }

    /// Resolves any lane id this app hands out, including ad-hoc ones.
    func lane(id: String) -> Lane {
        if let sub = subscription(id: id) { return lane(for: sub) }
        if id == Lane.unknownID { return .unknown }
        if id.hasPrefix(Lane.unlabeledPrefix) {
            return .unlabeled(email: String(id.dropFirst(Lane.unlabeledPrefix.count)))
        }
        return Lane(id: id, label: id, provider: .claude, accent: .graphite, visible: true, isConfigured: false)
    }

    /// Which lane a session belongs to. Stamped account first; a session with
    /// no stamp (older data) falls back to the repo rule for its directory.
    func laneID(for session: AgentSession) -> String {
        if session.tool == .codex { return codexSubscription.id }
        if let email = session.account, !email.isEmpty { return lane(forEmail: email).id }
        if let expected = expectedSubscription(forPath: session.cwd, owner: nil) { return expected.id }
        return Lane.unknownID
    }

    // MARK: Repo rules

    /// Owner rules beat path rules; among path rules the longest prefix wins.
    /// `predicate` lets callers skip rules that lack the field they need.
    func matchingRule(forPath path: String, owner: String?,
                      where predicate: (RepoRule) -> Bool = { _ in true }) -> RepoRule? {
        if let owner {
            let key = owner.lowercased()
            if let rule = rules.first(where: { $0.kind == .owner && $0.value == key && predicate($0) }) {
                return rule
            }
        }
        guard !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        var best: (rule: RepoRule, length: Int)?
        for rule in rules where rule.kind == .pathPrefix && predicate(rule) {
            var prefix = rule.value.hasPrefix("~") ? home + rule.value.dropFirst() : rule.value
            while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
            let matches = path == prefix || path.hasPrefix(prefix + "/")
            if matches, best == nil || prefix.count > best!.length {
                best = (rule, prefix.count)
            }
        }
        return best?.rule
    }

    func expectedGhAccount(forPath path: String, owner: String?) -> String? {
        matchingRule(forPath: path, owner: owner) { $0.ghAccount != nil }?.ghAccount
    }

    func expectedSubscription(forPath path: String, owner: String?) -> Subscription? {
        matchingRule(forPath: path, owner: owner) { $0.subscriptionID != nil }?
            .subscriptionID.flatMap(subscription(id:))
    }

    /// The session's login is a named subscription, a rule names a different
    /// one for this repository. Unlabeled logins and unruled paths never warn.
    func isCrossover(email: String, path: String, owner: String? = nil) -> Bool {
        guard let actual = subscription(forEmail: email),
              let expected = expectedSubscription(forPath: path, owner: owner) else { return false }
        return actual.id != expected.id
    }
}
