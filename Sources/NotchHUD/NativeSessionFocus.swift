import AppKit

@MainActor
enum NativeSessionFocus {
    static func focusOrca(handle: String, appURL: URL) async -> Bool {
        guard handle.hasPrefix("term_"), UUID(uuidString: String(handle.dropFirst(5))) != nil else { return false }
        let executable = appURL.appendingPathComponent("Contents/Resources/bin/orca")
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["terminal", "focus", "--terminal", handle]
            // This operation only selects a terminal; it never sends input.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()
            return process.terminationStatus == 0
        }.value
    }

    /// Native Ghostty focus selects both the tab and the split pane. A directory
    /// is used only when unique; duplicate matches require a unique title too.
    /// Ambiguity falls back to opening the app, never a guessed tab shortcut.
    static func focusGhostty(session: AgentSession) -> Bool {
        let source = ghosttyScript(cwd: session.cwd, title: session.conversationTitle ?? session.title)
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            FocusHelper.log("Ghostty native focus unavailable (Apple Event error \(error[NSAppleScript.errorNumber] ?? "unknown"))")
            return false
        }
        let focused = result.stringValue == "focused"
        FocusHelper.log("Ghostty native focus: \(focused ? "selected unique terminal" : "no unique terminal match")")
        return focused
    }

    nonisolated static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }

    nonisolated static func ghosttyScript(cwd: String, title: String) -> String {
        """
        set targetDirectory to \(appleScriptLiteral(cwd))
        set targetTitle to \(appleScriptLiteral(title))
        tell application id "com.mitchellh.ghostty"
            set candidates to {}
            if targetDirectory is not "" then
                set candidates to every terminal whose working directory is targetDirectory
            end if
            if (count of candidates) is not 1 and targetTitle is not "" then
                if (count of candidates) is 0 then set candidates to every terminal
                set titleMatches to {}
                repeat with candidate in candidates
                    if (name of candidate) contains targetTitle then
                        set end of titleMatches to contents of candidate
                    end if
                end repeat
                set candidates to titleMatches
            end if
            if (count of candidates) is 1 then
                focus (item 1 of candidates)
                return "focused"
            end if
            return "ambiguous"
        end tell
        """
    }
}
