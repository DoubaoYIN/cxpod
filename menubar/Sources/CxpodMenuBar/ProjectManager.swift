import Foundation

struct ProjectInfo {
    let path: String
    let name: String
    let lastUsed: Date
    let source: ProjectSource
}

enum ProjectSource {
    case manual
    case scanned
}

private struct ProjectsConfig: Codable {
    var scan_dirs: [String]
    var manual: [ManualEntry]
    struct ManualEntry: Codable {
        let path: String
        let name: String
    }
}

final class ProjectManager {
    var onChange: (() -> Void)?

    private let configURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configURL = home.appendingPathComponent(".cxpod/projects.json")
        ensureConfig()
    }

    func start() { watchConfig() }

    func stop() {
        fileSource?.cancel(); fileSource = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    func recentProjects(limit: Int = 30) -> [ProjectInfo] {
        var seen = Set<String>()
        var result: [ProjectInfo] = []
        let config = loadConfig()
        for entry in config.manual {
            let expanded = expandTilde(entry.path)
            guard FileManager.default.fileExists(atPath: expanded), seen.insert(expanded).inserted else { continue }
            result.append(ProjectInfo(path: expanded, name: entry.name, lastUsed: modificationDate(atPath: expanded), source: .manual))
        }
        for dir in config.scan_dirs {
            for proj in scanDirectory(expandTilde(dir)) {
                guard seen.insert(proj.path).inserted else { continue }
                result.append(proj)
            }
        }
        return result.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit).map { $0 }
    }

    func addManualProject(path: String) {
        var config = loadConfig()
        let expanded = expandTilde(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        if config.manual.contains(where: { expandTilde($0.path) == expanded }) { return }
        config.manual.append(ProjectsConfig.ManualEntry(path: expanded, name: (expanded as NSString).lastPathComponent))
        saveConfig(config)
    }

    func removeManualProject(path: String) {
        var config = loadConfig()
        let expanded = expandTilde(path)
        config.manual.removeAll { expandTilde($0.path) == expanded }
        saveConfig(config)
    }

    private func scanDirectory(_ dir: String) -> [ProjectInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { entry -> ProjectInfo? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let p = entry.path
            let hasGit = fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git"))
            guard hasGit else { return nil }
            return ProjectInfo(path: p, name: entry.lastPathComponent, lastUsed: modificationDate(atPath: p), source: .scanned)
        }
    }

    private func loadConfig() -> ProjectsConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ProjectsConfig.self, from: data) else {
            return ProjectsConfig(scan_dirs: ["~/Projects"], manual: [])
        }
        return config
    }

    private func saveConfig(_ config: ProjectsConfig) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }

    private func ensureConfig() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        saveConfig(ProjectsConfig(scan_dirs: ["~/Projects"], manual: []))
    }

    private func watchConfig() {
        stop()
        let path = configURL.path
        if !FileManager.default.fileExists(atPath: path) { watchParentDir(); return }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.onChange?()
            if source.data.contains(.delete) || source.data.contains(.rename) { self.watchConfig() }
        }
        source.setCancelHandler { [weak self] in if let fd = self?.fd, fd >= 0 { close(fd); self?.fd = -1 } }
        source.resume(); fileSource = source
    }

    private func watchParentDir() {
        let dirPath = configURL.deletingLastPathComponent().path
        let dirFD = open(dirPath, O_EVTONLY); guard dirFD >= 0 else { return }
        fd = dirFD
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.configURL.path) { self.watchConfig(); self.onChange?() }
        }
        source.setCancelHandler { [weak self] in if let fd = self?.fd, fd >= 0 { close(fd); self?.fd = -1 } }
        source.resume(); fileSource = source
    }

    private func expandTilde(_ path: String) -> String {
        path.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1)) : path
    }

    private func modificationDate(atPath path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}
