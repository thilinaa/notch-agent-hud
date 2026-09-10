import AppKit
import Foundation
import CryptoKit

/// Keeps the app current from GitHub Releases without a framework. A check is
/// one anonymous GET for the latest release; an install downloads the
/// notarized DMG, verifies the published SHA-256 and Gatekeeper's verdict,
/// swaps the bundle in place and relaunches. Nothing about the user is sent.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let dmgURL: URL
        let checksumURL: URL?
        let notes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(Release)
        case downloading(Release, Double)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Cached latest release so the panel can keep offering it after a failure.
    @Published private(set) var latest: Release?

    nonisolated static let repository = "thilinaa/notch-agent-hud"
    private var timer: Timer?
    private weak var configStore: ConfigStore?

    private init() {}

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
    }

    /// Dev builds are stamped 0.0.0-dev and must never be "updated" to a release.
    var isReleaseBuild: Bool { Self.parse(currentVersion) != nil && Notifier.available }

    func start(configStore: ConfigStore) {
        self.configStore = configStore
        guard isReleaseBuild else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfEnabled() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfEnabled() }
    }

    private func checkIfEnabled() {
        guard configStore?.config.preferences.checkForUpdates ?? true else { return }
        check()
    }

    /// One GET to the releases API. `manual` checks run even with automatic
    /// checks switched off, since the user asked.
    func check() {
        guard isReleaseBuild else { return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        let current = currentVersion
        Task.detached {
            let result = await Self.fetchLatest()
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.state = .failed(error.message)
                case .success(let release):
                    self.latest = release
                    self.state = Self.isNewer(release.version, than: current) ? .available(release) : .upToDate(Date())
                }
            }
        }
    }

    nonisolated private static func fetchLatest() async -> Result<Release, UpdateError> {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return .failure(UpdateError(message: "Bad release URL"))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure(UpdateError(message: "No response")) }
            guard http.statusCode == 200 else { return .failure(UpdateError(message: "GitHub answered \(http.statusCode)")) }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let release = parseRelease(obj) else { return .failure(UpdateError(message: "Unexpected release data")) }
            return .success(release)
        } catch {
            return .failure(UpdateError(message: error.localizedDescription))
        }
    }

    /// The fields the updater needs from a GitHub release object.
    nonisolated static func parseRelease(_ obj: [String: Any]) -> Release? {
        guard let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard parse(version) != nil else { return nil }
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let dmg = asset(".dmg") else { return nil }
        return Release(version: version, pageURL: page, dmgURL: dmg, checksumURL: asset(".dmg.sha256"),
                       notes: (obj["body"] as? String) ?? "")
    }

    // MARK: Versions

    /// "1.2.3" → [1, 2, 3]; anything else (0.0.0-dev, empty) is not a release.
    nonisolated static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parse(candidate), let b = parse(current) else { return false }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    /// Download, verify, swap, relaunch. The old bundle is kept in a temporary
    /// folder until the new one has launched, so a failure leaves the app as
    /// it was.
    func install() {
        guard case .available(let release) = state else {
            if let latest, Self.isNewer(latest.version, than: currentVersion) { state = .available(latest); install() }
            return
        }
        state = .downloading(release, 0)
        let target = Bundle.main.bundleURL
        Task.detached {
            do {
                let dmg = try await Self.download(release) { fraction in
                    Task { @MainActor in
                        let updater = Updater.shared
                        if case .downloading = updater.state { updater.state = .downloading(release, fraction) }
                    }
                }
                await MainActor.run { Updater.shared.state = .installing(release) }
                try Self.verifyChecksum(dmg, against: release)
                try Self.swap(dmg: dmg, into: target)
                await MainActor.run { Self.relaunch(target) }
            } catch {
                await MainActor.run { Updater.shared.state = .failed(error.localizedDescription) }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated private static func download(_ release: Release, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, resp) = try await session.bytes(from: release.dmgURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "Download failed") }
        let expected = resp.expectedContentLength
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHUD-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(release.dmgURL.lastPathComponent)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(256 * 1024)
        var received: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                handle.write(buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if expected > 0, Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date(); progress(Double(received) / Double(expected))
                }
            }
        }
        if !buffer.isEmpty { handle.write(buffer); received += Int64(buffer.count) }
        progress(1)
        return file
    }

    nonisolated private static func verifyChecksum(_ dmg: URL, against release: Release) throws {
        guard let checksumURL = release.checksumURL else { return }  // older releases had none
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        var published: String?
        let task = session.dataTask(with: checksumURL) { data, _, _ in
            published = data.flatMap { String(data: $0, encoding: .utf8) }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        guard let expected = published?.split(separator: " ").first.map(String.init)?.lowercased(), expected.count == 64 else {
            throw UpdateError(message: "Could not read the published checksum")
        }
        let data = try Data(contentsOf: dmg)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError(message: "The download did not match its published checksum") }
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    /// Mounts the DMG, asks Gatekeeper about the app inside, stages a copy next
    /// to the running bundle, then swaps names. The old bundle goes to a
    /// temporary folder rather than being deleted.
    nonisolated private static func swap(dmg: URL, into target: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("NotchHUD-mount-\(UUID().uuidString)")
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.status == 0 else { throw UpdateError(message: "Could not open the downloaded disk image") }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let source = apps.first else { throw UpdateError(message: "No app inside the disk image") }

        let verdict = run("/usr/sbin/spctl", ["--assess", "--type", "execute", source.path])
        guard verdict.status == 0 else { throw UpdateError(message: "Gatekeeper rejected the download") }
        let signature = run("/usr/bin/codesign", ["--verify", "--strict", source.path])
        guard signature.status == 0 else { throw UpdateError(message: "The download's signature did not verify") }

        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(target.lastPathComponent + ".update")
        try? fm.removeItem(at: staged)
        let copy = run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.status == 0 else {
            throw UpdateError(message: "Could not write to \(parent.path). Download the update from the release page instead.")
        }
        let parked = fm.temporaryDirectory.appendingPathComponent("NotchHUD-previous-\(UUID().uuidString).app")
        do {
            try fm.moveItem(at: target, to: parked)
            try fm.moveItem(at: staged, to: target)
        } catch {
            // Put the old one back if the second move failed.
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: parked, to: target) }
            try? fm.removeItem(at: staged)
            throw UpdateError(message: "Could not replace the app: \(error.localizedDescription)")
        }
        // The running process keeps its mapped binary alive; the files can go.
        try? fm.removeItem(at: parked)
        try? fm.removeItem(at: dmg.deletingLastPathComponent())
    }

    /// `open` from a detached shell after we exit, so the new bundle launches
    /// once this process has let go of the old one.
    private static func relaunch(_ target: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
