import AppKit

enum TerminalAdapterError: Error, CustomStringConvertible {
    case scriptFailed(String)

    var description: String {
        switch self {
        case .scriptFailed(let m): return m
        }
    }
}

/// Opens a new terminal window and runs `command` in it.
protocol TerminalAdapter {
    var name: String { get }
    var identifier: String { get }
    func openNewWindow(command: String, title: String?) throws
}

/// Ghostty (preferred — session-local config works well with tmux).
final class GhosttyAdapter: TerminalAdapter {
    let name = "Ghostty"
    let identifier = "ghostty"

    func openNewWindow(command: String, title: String? = nil) throws {
        var full = ""
        if let t = title {
            full += "printf '\\033]2;%s\\007' \(shellQuote(t)); "
        }
        full += command
        let escaped = appleScriptEscape(full)

        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.mitchellh.ghostty"
        }

        let script: String
        if isRunning {
            script = """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration from {initial input:"\(escaped)" & (ASCII character 10)}
                new window with configuration cfg
            end tell
            """
        } else {
            script = """
            tell application "Ghostty"
                activate
            end tell
            delay 1.5
            tell application "Ghostty"
                set term to focused terminal of selected tab of front window
                input text "\(escaped)" & (ASCII character 10) to term
            end tell
            """
        }
        try runAppleScript(script)
    }
}

final class ITerm2Adapter: TerminalAdapter {
    let name = "iTerm2"
    let identifier = "iterm2"

    func openNewWindow(command: String, title: String? = nil) throws {
        let escaped = appleScriptEscape(command)
        var script = """
        tell application "iTerm2"
            activate
            create window with default profile
            tell current session of current window
                write text "\(escaped)"
        """
        if let t = title {
            script += "\n            set name to \"\(appleScriptEscape(t))\""
        }
        script += """

            end tell
        end tell
        """
        try runAppleScript(script)
    }
}

final class TerminalAppAdapter: TerminalAdapter {
    let name = "Terminal"
    let identifier = "terminal"

    func openNewWindow(command: String, title: String? = nil) throws {
        let escaped = appleScriptEscape(command)
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        try runAppleScript(script)
    }
}

final class TerminalRegistry {
    static let shared = TerminalRegistry()

    let adapters: [TerminalAdapter] = [
        GhosttyAdapter(),
        ITerm2Adapter(),
        TerminalAppAdapter(),
    ]

    var defaultAdapter: TerminalAdapter {
        // Prefer whichever is currently running, else Ghostty.
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        if running.contains("com.mitchellh.ghostty") { return adapters[0] }
        if running.contains("com.googlecode.iterm2") { return adapters[1] }
        if running.contains("com.apple.Terminal")    { return adapters[2] }
        return adapters[0]
    }

    func adapter(for identifier: String) -> TerminalAdapter? {
        adapters.first { $0.identifier == identifier }
    }
}

private func runAppleScript(_ source: String) throws {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        throw TerminalAdapterError.scriptFailed("无法创建 AppleScript")
    }
    script.executeAndReturnError(&error)
    if let error = error {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
        throw TerminalAdapterError.scriptFailed(msg)
    }
}

func shellQuote(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

private func appleScriptEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
