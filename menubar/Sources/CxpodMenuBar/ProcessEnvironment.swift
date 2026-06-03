import Foundation

func cxpodProcessEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let additions = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(home)/.local/bin",
    ]
    let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    env["PATH"] = (additions + [existing]).joined(separator: ":")
    return env
}
