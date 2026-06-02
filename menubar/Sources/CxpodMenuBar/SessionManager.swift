import Foundation

/// Represents one cxpod tmux session read from ~/.cxpod/state/cx-N.json.
struct SessionInfo {
    let windowID: String
    let provider: String
    let model: String
    let projectDir: String
    let updatedAt: String
    let tmuxTarget: String

    var projectName: String {
        (projectDir as NSString).lastPathComponent
    }

    var sessionNumber: Int {
        if let suffix = windowID.split(separator: "-").last, let n = Int(suffix) { return n }
        return 0
    }

    var sortKey: Int { sessionNumber }
}

/// Reads ~/.cxpod/state/*.json and keeps track of live tmux sessions.
final class SessionManager {
    var sessions: [SessionInfo] = []
    var onChange: (() -> Void)?

    private let stateDir: URL
    private var timer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateDir = home.appendingPathComponent(".cxpod/state", isDirectory: true)
    }

    func start() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: stateDir,
                                                       includingPropertiesForKeys: nil) else {
            if !sessions.isEmpty {
                sessions = []
                onChange?()
            }
            return
        }

        var newSessions: [SessionInfo] = []
        for file in files {
            guard file.pathExtension == "json",
                  file.lastPathComponent.hasPrefix("cx-") else { continue }
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let wid = obj["window_id"] as? String ?? file.deletingPathExtension().lastPathComponent
            let prov = obj["provider"] as? String ?? "?"
            let mdl = obj["model"] as? String ?? ""
            let dir = obj["project_dir"] as? String ?? ""
            let upd = obj["updated_at"] as? String ?? ""
            let tgt = obj["tmux_target"] as? String ?? ""

            // Check whether tmux session actually exists.
            if tmuxSessionExists(wid) {
                newSessions.append(SessionInfo(
                    windowID: wid, provider: prov, model: mdl,
                    projectDir: dir, updatedAt: upd, tmuxTarget: tgt
                ))
            }
        }

        newSessions.sort { $0.sortKey < $1.sortKey }

        if newSessions.map(\.windowID) != sessions.map(\.windowID)
            || newSessions.map(\.provider) != sessions.map(\.provider) {
            sessions = newSessions
            onChange?()
        } else {
            sessions = newSessions
        }
    }

    private func tmuxSessionExists(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux", "has-session", "-t", name]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
