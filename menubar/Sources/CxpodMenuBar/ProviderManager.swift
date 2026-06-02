import Foundation

/// One provider definition from providers/*.json.
struct ProviderInfo {
    let id: String
    let displayName: String
    let badgeEmoji: String
    let source: URL       // file path

    var badge: String { "\(badgeEmoji) \(displayName)" }
}

/// Discovers provider JSON files from two locations:
///   1. ~/.cxpod/providers/   (user overrides, takes priority)
///   2. <repo>/providers/     (bundled examples)
final class ProviderManager {
    var providers: [ProviderInfo] = []
    var onChange: (() -> Void)?

    private var timer: Timer?

    func availableProviders() -> [String] {
        providers.map(\.id)
    }

    func currentProvider() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cxpod/current-provider")
        return try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read the active provider from Codex.app's `~/.codex/config.toml`.
    func currentCodexAppProvider() -> String? {
        guard let head = readCodexConfigHead() else { return nil }
        return Self.parseTopLevelString(head, key: "model_provider")
    }

    /// Provider ids that have a `[model_providers.<id>]` section in
    /// `~/.codex/config.toml`. Lets the UI offer providers the user
    /// already configured directly inside Codex.app (e.g. a custom relay).
    func installedCodexAppProviders() -> [String] {
        guard let text = readCodexConfig() else { return [] }
        let pattern = #"(?m)^\[model_providers\.([A-Za-z0-9._-]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>(); var out: [String] = []
        for m in matches where m.numberOfRanges >= 2 {
            let id = ns.substring(with: m.range(at: 1))
            if !seen.contains(id) { seen.insert(id); out.append(id) }
        }
        return out
    }

    private func readCodexConfig() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Only the head before the first `[section]` — top-level key parsing.
    private func readCodexConfigHead() -> String? {
        guard let text = readCodexConfig() else { return nil }
        if let r = text.range(of: #"(?m)^\["#, options: .regularExpression) {
            return String(text[..<r.lowerBound])
        }
        return text
    }

    private static func parseTopLevelString(_ text: String, key: String) -> String? {
        let pattern = #"(?m)^\#(NSRegularExpression.escapedPattern(for: key))\s*=\s*"((?:\\.|[^"\\])*)"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    func start() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userDir = home.appendingPathComponent(".cxpod/providers", isDirectory: true)

        // Find the repo providers dir by looking relative to the binary or
        // falling back to ~/Projects/cxpod/providers.
        let repoDir = findRepoProviders()

        var seen = Set<String>()
        var newProviders: [ProviderInfo] = []

        for dir in [userDir, repoDir] {
            guard let dir = dir,
                  let files = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard file.pathExtension == "json" else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                guard !name.hasSuffix(".example") else { continue }
                guard !seen.contains(name) else { continue }
                seen.insert(name)

                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let id = obj["id"] as? String ?? name
                let dn = obj["display_name"] as? String ?? id
                let emoji = obj["badge_emoji"] as? String ?? "⚪"
                newProviders.append(ProviderInfo(
                    id: id, displayName: dn, badgeEmoji: emoji, source: file
                ))
            }
        }

        if newProviders.map(\.id) != providers.map(\.id) {
            providers = newProviders
            onChange?()
        } else {
            providers = newProviders
        }
    }

    private func findRepoProviders() -> URL? {
        // Try: binary is inside CxPod.app/Contents/MacOS/CxpodMenuBar
        // Repo would be at ../../../../providers if bundled from repo.
        // Otherwise fall back to ~/Projects/cxpod/providers.
        let fm = FileManager.default
        let candidates: [String] = [
            ProcessInfo.processInfo.environment["CXPOD_REPO"].map { $0 + "/providers" },
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Projects/cxpod/providers").path,
        ].compactMap { $0 }

        for c in candidates {
            if fm.isDirectory(atPath: c) {
                return URL(fileURLWithPath: c, isDirectory: true)
            }
        }
        return nil
    }
}

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
