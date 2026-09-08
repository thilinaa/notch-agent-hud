import AppKit
import Darwin

/// Match the exact open rollout file, never a working directory (several hosts
/// can run sessions in the same repo). Capture only process IDs and file paths.
enum SessionHostResolver {
    static func parseOpenFiles(_ output: String) -> [String: Int32] {
        var result: [String: Int32] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid {
                let path = String(line.dropFirst())
                if path.contains("/sessions/"), path.contains("/rollout-"), path.hasSuffix(".jsonl") {
                    result[path] = pid
                }
            }
        }
        return result
    }

    struct ProcessInfo {
        let parent: Int32
        let executable: String
    }

    static func parseProcesses(_ output: String) -> [Int32: ProcessInfo] {
        var result: [Int32: ProcessInfo] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            result[pid] = ProcessInfo(parent: parent, executable: String(fields[2]))
        }
        return result
    }

    static func applicationPath(for pid: Int32, processes: [Int32: ProcessInfo]) -> String? {
        var current = pid
        var seen: Set<Int32> = []
        var application: String?
        while current > 1, seen.insert(current).inserted, let process = processes[current] {
            if process.executable.hasPrefix("/"), let end = process.executable.range(of: ".app/") {
                // Electron helpers are nested bundles: select the outer application.
                let candidate = String(process.executable[..<end.lowerBound]) + ".app"
                // CLI wrappers can themselves be .app bundles. Continue to the
                // outer host (for example ClaudeCode.app -> shell -> Ghostty).
                if !candidate.hasSuffix("/ClaudeCode.app") { application = candidate }
            }
            current = process.parent
        }
        return application
    }

    struct Snapshot: Sendable {
        var rollouts: [String: String] = [:]
        var claudeProcesses: [Int32: String] = [:]
        var rolloutTargets: [String: String] = [:]
        var claudeTargets: [Int32: String] = [:]
    }

    static func snapshot() async -> Snapshot {
        await Task.detached(priority: .utility) {
            let files = parseOpenFiles(run("/usr/sbin/lsof", ["-nP", "-c", "codex", "-Fpn"]))
            let processes = parseProcesses(run("/bin/ps", ["-axo", "pid=,ppid=,comm="]))
            var hosts: [String: String] = [:]
            var targets: [String: String] = [:]
            for (path, pid) in files {
                if let app = applicationPath(for: pid, processes: processes),
                   let id = Bundle(path: app)?.bundleIdentifier {
                    hosts[path] = id
                    if id == "com.stablyai.orca" { targets[path] = orcaTerminalHandle(pid: pid) }
                }
            }
            var claudeHosts: [Int32: String] = [:]
            var claudeTargets: [Int32: String] = [:]
            for (pid, process) in processes where process.executable.lowercased().contains("claude") {
                if let path = applicationPath(for: pid, processes: processes),
                   let id = Bundle(path: path)?.bundleIdentifier {
                    claudeHosts[pid] = id
                    if id == "com.stablyai.orca" { claudeTargets[pid] = orcaTerminalHandle(pid: pid) }
                }
            }
            return Snapshot(rollouts: hosts, claudeProcesses: claudeHosts,
                            rolloutTargets: targets, claudeTargets: claudeTargets)
        }.value
    }

    /// The process environment contains credentials too: retain only the
    /// allowlisted Orca terminal handle, never log or persist the raw buffer.
    private static func orcaTerminalHandle(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 4_000_000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return parseOrcaTerminalHandle(Data(bytes.prefix(size)))
    }

    static func parseOrcaTerminalHandle(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0, argc < 100_000 else { return nil }
        var cursor = 4
        // Executable path and alignment padding precede argc argument strings.
        while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc {
            guard cursor < bytes.count else { return nil }
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        guard cursor < bytes.count else { return nil }
        for entry in bytes[cursor...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            let prefix = "ORCA_TERMINAL_HANDLE="
            if text.hasPrefix(prefix) {
                let handle = String(text.dropFirst(prefix.count))
                guard handle.hasPrefix("term_"), UUID(uuidString: String(handle.dropFirst(5))) != nil else { return nil }
                return handle
            }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
