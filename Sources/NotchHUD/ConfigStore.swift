import Foundation
import Combine

/// Live, observable configuration. Edits are saved back to the config file
/// shortly after they happen; every consumer reads `config` through the store
/// so settings changes apply without a relaunch.
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: HUDConfig {
        didSet { if config != oldValue { scheduleSave() } }
    }

    private let url: URL
    private var saveTask: Task<Void, Never>?
    private var watcher: Timer?
    private var knownModification: Date?

    init(url: URL = HUDConfig.defaultURL, watchFile: Bool = true) {
        self.url = url
        if HUDConfig.isUnreadable(url) {
            // Keep whatever the user had before defaults get written over it.
            let broken = url.deletingLastPathComponent().appendingPathComponent("config.unreadable.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.copyItem(at: url, to: broken)
            NSLog("NotchHUD: %@ is not valid JSON; kept a copy at %@ and started from defaults", url.path, broken.path)
        }
        config = HUDConfig.load(from: url)
        knownModification = Self.modificationDate(url)
        if watchFile {
            // Hand edits in a text editor apply live too. Polling mtime every
            // couple of seconds is cheaper and simpler than a dispatch source
            // that must survive atomic replaces.
            watcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reloadIfChangedOnDisk() }
            }
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Picks up a file the user edited outside the app. Our own saves update
    /// `knownModification`, so they never bounce back as a reload.
    func reloadIfChangedOnDisk() {
        guard saveTask == nil else { return }  // an in-app edit is about to overwrite it anyway
        let current = Self.modificationDate(url)
        guard current != knownModification else { return }
        // A text editor may have saved half a file; wait for a readable one.
        guard !HUDConfig.isUnreadable(url) else { return }
        knownModification = current
        let fresh = HUDConfig.load(from: url)
        if fresh != config {
            config = fresh
            saveTask?.cancel(); saveTask = nil  // the reload itself needs no save
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try config.save(to: url)
            knownModification = Self.modificationDate(url)
        } catch {
            NSLog("NotchHUD: could not save config: %@", error.localizedDescription)
        }
    }

    // MARK: Preferences

    func updatePreferences(_ change: (inout HUDPreferences) -> Void) {
        var prefs = config.preferences
        change(&prefs)
        config.preferences = prefs
    }

    // MARK: Rules

    @discardableResult
    func addRule(kind: RepoRule.Kind, value: String, ghAccount: String? = nil, subscriptionID: String? = nil) -> RepoRule {
        let rule = RepoRule(kind: kind, value: value, ghAccount: ghAccount, subscriptionID: subscriptionID)
        config.rules.append(rule)
        return rule
    }

    func updateRule(_ id: String, _ change: (inout RepoRule) -> Void) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = config.rules[index]
        change(&rule)
        if rule.kind == .owner { rule.value = rule.value.lowercased() }
        if rule.ghAccount?.isEmpty == true { rule.ghAccount = nil }
        config.rules[index] = rule
    }

    func removeRule(_ id: String) {
        config.rules.removeAll { $0.id == id }
    }

    // MARK: Detection

    /// First-load defaults come from the machine, not from assumptions: with
    /// no Claude subscription named yet, the login Claude Code is using becomes
    /// the first one; Codex is listed once its auth or a session shows up.
    /// Anything beyond that is the user's call in Settings.
    func adoptDetectedLogins(sessions: [AgentSession],
                             activeClaudeEmail: String? = AccountDetection.activeClaudeEmail(),
                             codexPresent: Bool? = nil) {
        if claudeSubscriptions.isEmpty, let email = activeClaudeEmail {
            addClaudeAccount(email: email)
        }
        let codexSeen = codexPresent ?? AccountDetection.codexPresent(sessions: sessions)
        if !config.hasCodex, codexSeen {
            var codex = HUDConfig.defaultCodex
            codex.email = AccountDetection.codexEmail(sessions: sessions)
            config.subscriptions.append(codex)
        }
    }

    // MARK: Subscriptions

    var claudeSubscriptions: [Subscription] {
        config.subscriptions.filter { $0.provider == .claude }
    }

    func update(_ id: String, _ change: (inout Subscription) -> Void) {
        guard let index = config.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var sub = config.subscriptions[index]
        change(&sub)
        sub.email = sub.email?.lowercased()
        config.subscriptions[index] = sub
    }

    /// Adds a Claude login. Returns the existing entry if the email is already named.
    @discardableResult
    func addClaudeAccount(email: String, label: String? = nil) -> Subscription {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = config.subscription(forEmail: key) { return existing }
        let count = claudeSubscriptions.count
        let sub = Subscription(provider: .claude, email: key,
                               label: label ?? Lane.unlabeled(email: key).label.capitalized,
                               accent: nextAccent(afterCount: count))
        // Keep Codex last so the list reads Claude accounts first.
        let codexIndex = config.subscriptions.firstIndex { $0.provider == .codex } ?? config.subscriptions.endIndex
        config.subscriptions.insert(sub, at: codexIndex)
        return sub
    }

    /// Removes a Claude subscription; rules that pointed at it keep their `gh`
    /// account and lose the subscription link. Codex cannot be removed.
    func remove(_ id: String) {
        guard let sub = config.subscription(id: id), sub.provider == .claude else { return }
        config.subscriptions.removeAll { $0.id == id }
        for index in config.rules.indices where config.rules[index].subscriptionID == id {
            config.rules[index].subscriptionID = nil
        }
    }

    /// First preset not yet used by a Claude subscription; falls back to the cycle.
    private func nextAccent(afterCount count: Int) -> SubscriptionAccent {
        let used = Set(claudeSubscriptions.map { $0.accent })
        let cycle: [SubscriptionAccent] = [.blue, .violet, .teal, .green, .amber, .rose]
        return cycle.first { !used.contains($0) } ?? SubscriptionAccent.preset(count)
    }
}

/// Logins the machine already knows about, so naming them is a confirmation
/// rather than typing. Read-only probes; nothing here writes.
enum AccountDetection {
    struct Detected: Identifiable, Equatable {
        var id: String { email }
        let email: String
        /// True for the login `claude` is currently using.
        let active: Bool
        /// How many tracked sessions were stamped with this login.
        let sessions: Int
    }

    /// The account Claude Code is signed in with right now.
    static func activeClaudeEmail() -> String? {
        let env = ProcessInfo.processInfo.environment
        let dir = env["CLAUDE_CONFIG_DIR"] ?? Home.directory
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/.claude.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = (obj["oauthAccount"] as? [String: Any])?["emailAddress"] as? String,
              !email.isEmpty else { return nil }
        return email.lowercased()
    }

    /// Claude logins seen anywhere, active first, then by how often they appear.
    static func claudeLogins(sessions: [AgentSession]) -> [Detected] {
        var counts: [String: Int] = [:]
        for s in sessions where s.tool == .claude {
            if let email = s.account?.lowercased(), !email.isEmpty { counts[email, default: 0] += 1 }
        }
        let active = activeClaudeEmail()
        if let active, counts[active] == nil { counts[active] = 0 }
        return counts.map { Detected(email: $0.key, active: $0.key == active, sessions: $0.value) }
            .sorted {
                if $0.active != $1.active { return $0.active }
                if $0.sessions != $1.sessions { return $0.sessions > $1.sessions }
                return $0.email < $1.email
            }
    }

    /// Codex is on this Mac if it has logged in or has ever run a session.
    static func codexPresent(sessions: [AgentSession]) -> Bool {
        FileManager.default.fileExists(atPath: Home.directory + "/.codex/auth.json")
            || sessions.contains { $0.tool == .codex }
    }

    /// The Codex login, from the newest session that carries one.
    static func codexEmail(sessions: [AgentSession]) -> String? {
        sessions.filter { $0.tool == .codex && !($0.account ?? "").isEmpty }
            .max { $0.lastEvent < $1.lastEvent }?.account?.lowercased()
    }
}
