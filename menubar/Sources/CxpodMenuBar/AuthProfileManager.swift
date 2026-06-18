import Foundation

final class AuthProfileManager {
    var profiles: [String] = []
    var onChange: (() -> Void)?

    private let fm = FileManager.default
    private let home: URL
    private let accountsDir: URL
    private let legacyAuthURL: URL
    private let currentProfileURL: URL
    private let codexAppProfileURL: URL
    private var timer: Timer?

    init() {
        home = fm.homeDirectoryForCurrentUser
        accountsDir = home.appendingPathComponent(".cxpod/codex-auth/accounts", isDirectory: true)
        legacyAuthURL = home.appendingPathComponent(".cxpod/codex-auth/oauth.json")
        currentProfileURL = home.appendingPathComponent(".cxpod/current-auth-profile")
        codexAppProfileURL = home.appendingPathComponent(".cxpod/current-codex-app-auth-profile")
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

    func availableProfiles() -> [String] {
        profiles
    }

    func currentProfile() -> String? {
        if let profile = readProfileFile(currentProfileURL), isValidProfileName(profile) {
            return profile
        }
        if profiles.contains("default") { return "default" }
        return profiles.first
    }

    func currentCodexAppProfile() -> String? {
        if let profile = readProfileFile(codexAppProfileURL), isValidProfileName(profile) {
            return profile
        }
        return nil
    }

    func reload() {
        var seen = Set<String>()
        var newProfiles: [String] = []

        if let files = try? fm.contentsOfDirectory(at: accountsDir, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard file.pathExtension == "json" else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                guard isValidProfileName(name), !seen.contains(name) else { continue }
                seen.insert(name)
                newProfiles.append(name)
            }
        }

        if fm.fileExists(atPath: legacyAuthURL.path), !seen.contains("default") {
            newProfiles.insert("default", at: 0)
        }

        if newProfiles != profiles {
            profiles = newProfiles
            onChange?()
        } else {
            profiles = newProfiles
        }
    }

    private func readProfileFile(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isValidProfileName(_ value: String) -> Bool {
        guard value != ".", value != ".." else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}
