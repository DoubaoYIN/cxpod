import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CodexSessionThread: Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    let modelProvider: String
    let updatedAtMs: Int64
    let archived: Bool
    let rolloutPath: String

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名会话" : trimmed
    }

    func overridingCwd(_ newCwd: String) -> CodexSessionThread {
        CodexSessionThread(
            id: id,
            title: title,
            cwd: newCwd,
            modelProvider: modelProvider,
            updatedAtMs: updatedAtMs,
            archived: archived,
            rolloutPath: rolloutPath
        )
    }
}

struct CodexSessionProject: Identifiable, Hashable {
    let path: String
    let name: String
    let count: Int
    let latestUpdatedAtMs: Int64
    let isUnassigned: Bool
    let isManaged: Bool
    let isSystem: Bool

    var id: String { path }
}

private struct SavedCodexProject: Codable, Hashable {
    var path: String
    var name: String
}

private struct SavedCodexProjectsConfig: Codable {
    var projects: [SavedCodexProject]
    var pendingThreadProjects: [String: String]

    init(projects: [SavedCodexProject], pendingThreadProjects: [String: String] = [:]) {
        self.projects = projects
        self.pendingThreadProjects = pendingThreadProjects
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case pendingThreadProjects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([SavedCodexProject].self, forKey: .projects) ?? []
        pendingThreadProjects = try container.decodeIfPresent([String: String].self, forKey: .pendingThreadProjects) ?? [:]
    }
}

private struct SQLiteThreadRow: Decodable {
    let id: String
    let title: String?
    let cwd: String
    let modelProvider: String
    let updatedAtMs: Int64?
    let archived: Int
    let rolloutPath: String
}

private struct CodexAppSidebarState {
    var projectOrder: [String]
    var projectlessThreadIDs: Set<String>
    var threadWorkspaceRootHints: [String: String]

    static let empty = CodexAppSidebarState(projectOrder: [], projectlessThreadIDs: [], threadWorkspaceRootHints: [:])
}

struct CodexSessionMutationSummary {
    let changedThreads: Int
    let rolloutWarnings: Int
}

enum CodexSessionOrganizerError: LocalizedError {
    case sqliteFailed(String)
    case invalidProjectName
    case cannotDeleteUnassigned
    case cannotRenameUnassigned
    case codexRunning
    case rolloutFirstLineTooLarge(String)
    case rolloutRewriteWouldBeExpensive(String)

    var errorDescription: String? {
        switch self {
        case .sqliteFailed(let message):
            return message
        case .invalidProjectName:
            return "项目名称不能为空"
        case .cannotDeleteUnassigned:
            return "未归类不能删除"
        case .cannotRenameUnassigned:
            return "未归类不能重命名"
        case .codexRunning:
            return "Codex.app 正在运行。请先退出 Codex.app，再整理会话；修改完成后重新打开 Codex.app。"
        case .rolloutFirstLineTooLarge(let path):
            return "rollout 元数据过大，已跳过：\(path)"
        case .rolloutRewriteWouldBeExpensive(let path):
            return "rollout 文件较大，避免整文件重写，已跳过：\(path)"
        }
    }
}

final class CodexSessionOrganizer {
    private let fm = FileManager.default
    private let home: URL
    private let codexHome: URL
    private let stateDB: URL
    private let globalStateURL: URL
    private let configURL: URL
    private let managedRoot: URL
    private let unassignedURL: URL
    private let deletedProjectURL: URL
    private var backupRootURL: URL?

    init() {
        home = fm.homeDirectoryForCurrentUser
        codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        stateDB = codexHome.appendingPathComponent("state_5.sqlite")
        globalStateURL = codexHome.appendingPathComponent(".codex-global-state.json")
        configURL = home.appendingPathComponent(".cxpod/codex-session-projects.json")
        managedRoot = home.appendingPathComponent(".cxpod/p", isDirectory: true)
        unassignedURL = managedRoot.appendingPathComponent("未归类", isDirectory: true)
        deletedProjectURL = managedRoot.appendingPathComponent("待整理-原项目已删除", isDirectory: true)
    }

    var unassignedPath: String { unassignedURL.path }
    var deletedProjectPath: String { deletedProjectURL.path }

    func readThreads(includeArchived: Bool) throws -> [CodexSessionThread] {
        let whereClause = includeArchived ? "" : "WHERE archived = 0"
        let sql = """
        SELECT id,
               CASE WHEN title != '' THEN title ELSE first_user_message END AS title,
               cwd,
               model_provider AS modelProvider,
               COALESCE(updated_at_ms, updated_at * 1000) AS updatedAtMs,
               archived,
               rollout_path AS rolloutPath
        FROM threads
        \(whereClause)
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC, id DESC;
        """
        let output = try runSQLite(arguments: ["-json", stateDB.path, sql])
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let rows = try JSONDecoder().decode([SQLiteThreadRow].self, from: Data(output.utf8))
        return rows.map {
            CodexSessionThread(
                id: $0.id,
                title: $0.title ?? "",
                cwd: $0.cwd,
                modelProvider: $0.modelProvider,
                updatedAtMs: $0.updatedAtMs ?? 0,
                archived: $0.archived != 0,
                rolloutPath: $0.rolloutPath
            )
        }
    }

    func pendingMoves() -> [String: String] {
        loadSavedProjects().pendingThreadProjects
    }

    func savePendingMoves(_ pending: [String: String]) {
        var config = loadSavedProjects()
        config.pendingThreadProjects = pending
        saveProjects(config)
    }

    func threadsByApplyingPendingMoves(_ threads: [CodexSessionThread]) -> [CodexSessionThread] {
        let pending = pendingMoves()
        let saved = loadSavedProjects()
        let sidebarState = loadCodexAppSidebarState()
        return threads.map { thread in
            if let target = pending[thread.id] {
                return thread.overridingCwd(target)
            }
            let displayPath = displayProjectPath(for: thread, saved: saved, sidebarState: sidebarState)
            guard displayPath != thread.cwd else { return thread }
            return thread.overridingCwd(displayPath)
        }
    }

    func projects(from threads: [CodexSessionThread]) -> [CodexSessionProject] {
        let saved = loadSavedProjects()
        let sidebarState = loadCodexAppSidebarState()
        var savedByPath: [String: SavedCodexProject] = [:]
        for project in saved.projects { savedByPath[project.path] = project }
        let codexProjectPaths = Set(sidebarState.projectOrder)
        let savedProjectPaths = Set(saved.projects.map(\.path))

        var counts: [String: Int] = [:]
        var latest: [String: Int64] = [:]
        for thread in threads {
            counts[thread.cwd, default: 0] += 1
            latest[thread.cwd] = max(latest[thread.cwd] ?? 0, thread.updatedAtMs)
        }

        var paths = Set<String>()
        paths.insert(unassignedURL.path)
        paths.insert(deletedProjectURL.path)
        for path in sidebarState.projectOrder { paths.insert(path) }
        for project in saved.projects { paths.insert(project.path) }
        for thread in threads where thread.cwd == unassignedURL.path
            || thread.cwd == deletedProjectURL.path
            || codexProjectPaths.contains(thread.cwd)
            || savedProjectPaths.contains(thread.cwd) {
            paths.insert(thread.cwd)
        }

        return paths.map { path in
            let isUnassigned = path == unassignedURL.path
            let isDeletedProject = path == deletedProjectURL.path
            let saved = savedByPath[path]
            return CodexSessionProject(
                path: path,
                name: systemProjectName(path: path) ?? saved?.name ?? defaultProjectName(for: path),
                count: counts[path] ?? 0,
                latestUpdatedAtMs: latest[path] ?? 0,
                isUnassigned: isUnassigned,
                isManaged: saved != nil || path.hasPrefix(managedRoot.path + "/"),
                isSystem: isUnassigned || isDeletedProject
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSystem != rhs.isSystem { return lhs.isSystem }
            if lhs.isUnassigned != rhs.isUnassigned { return lhs.isUnassigned }
            let lhsIndex = sidebarState.projectOrder.firstIndex(of: lhs.path)
            let rhsIndex = sidebarState.projectOrder.firstIndex(of: rhs.path)
            if lhsIndex != rhsIndex {
                return (lhsIndex ?? Int.max) < (rhsIndex ?? Int.max)
            }
            if lhs.latestUpdatedAtMs != rhs.latestUpdatedAtMs { return lhs.latestUpdatedAtMs > rhs.latestUpdatedAtMs }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func createProject(named rawName: String) throws -> CodexSessionProject {
        let name = normalizedProjectName(rawName)
        guard !name.isEmpty else { throw CodexSessionOrganizerError.invalidProjectName }
        let path = uniqueManagedPath(for: name)
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        upsertSavedProject(path: path.path, name: name)
        return CodexSessionProject(path: path.path, name: name, count: 0, latestUpdatedAtMs: 0, isUnassigned: false, isManaged: true, isSystem: false)
    }

    func moveThreads(_ threads: [CodexSessionThread], to project: CodexSessionProject) throws -> CodexSessionMutationSummary {
        guard !threads.isEmpty else { return CodexSessionMutationSummary(changedThreads: 0, rolloutWarnings: 0) }
        try ensureCodexNotRunning()
        try fm.createDirectory(atPath: project.path, withIntermediateDirectories: true)
        try backupDatabaseIfNeeded()

        let ids = threads.map { sqlQuote($0.id) }.joined(separator: ",")
        let sql = "UPDATE threads SET cwd = \(sqlQuote(project.path)) WHERE id IN (\(ids));"
        _ = try runSQLite(arguments: [stateDB.path, sql])
        let warnings = rewriteRollouts(threads, newCwd: project.path)
        return CodexSessionMutationSummary(changedThreads: threads.count, rolloutWarnings: warnings)
    }

    func applyPendingMoves(_ pending: [String: String], originalThreads: [CodexSessionThread]) throws -> CodexSessionMutationSummary {
        guard !pending.isEmpty else { return CodexSessionMutationSummary(changedThreads: 0, rolloutWarnings: 0) }
        try ensureCodexNotRunning()
        try backupDatabaseIfNeeded()

        let originalByID = Dictionary(uniqueKeysWithValues: originalThreads.map { ($0.id, $0) })
        var changedThreads: [CodexSessionThread] = []
        var rolloutWarnings = 0

        for (threadID, targetPath) in pending.sorted(by: { $0.key < $1.key }) {
            guard let thread = originalByID[threadID] else { continue }
            if targetPath == unassignedURL.path {
                markThreadProjectless(threadID: threadID, workspaceRootHint: threadWorkspaceRootHint(for: thread))
            } else {
                guard thread.cwd != targetPath else { continue }
                try fm.createDirectory(atPath: targetPath, withIntermediateDirectories: true)
                _ = try runSQLite(arguments: [
                    stateDB.path,
                    "UPDATE threads SET cwd = \(sqlQuote(targetPath)) WHERE id = \(sqlQuote(threadID));"
                ])
                markThreadAssigned(threadID: threadID, projectPath: targetPath)
                rolloutWarnings += rewriteRollouts([thread], newCwd: targetPath)
            }
            changedThreads.append(thread)
        }

        savePendingMoves([:])
        return CodexSessionMutationSummary(changedThreads: changedThreads.count, rolloutWarnings: rolloutWarnings)
    }

    func renameProject(_ project: CodexSessionProject, to rawName: String) throws -> CodexSessionMutationSummary {
        guard !project.isSystem else { throw CodexSessionOrganizerError.cannotRenameUnassigned }
        try ensureCodexNotRunning()
        let name = normalizedProjectName(rawName)
        guard !name.isEmpty else { throw CodexSessionOrganizerError.invalidProjectName }
        let newPath = uniqueManagedPath(for: name, allowingExistingPath: project.path)
        try fm.createDirectory(at: newPath.deletingLastPathComponent(), withIntermediateDirectories: true)

        if project.path.hasPrefix(managedRoot.path + "/"), fm.fileExists(atPath: project.path), !fm.fileExists(atPath: newPath.path) {
            try? fm.moveItem(atPath: project.path, toPath: newPath.path)
        }
        if !fm.fileExists(atPath: newPath.path) {
            try fm.createDirectory(at: newPath, withIntermediateDirectories: true)
        }

        let threads = try readThreads(matchingCwd: project.path)
        try backupDatabaseIfNeeded()
        _ = try runSQLite(arguments: [
            stateDB.path,
            "UPDATE threads SET cwd = \(sqlQuote(newPath.path)) WHERE cwd = \(sqlQuote(project.path));"
        ])
        removeSavedProject(path: project.path)
        upsertSavedProject(path: newPath.path, name: name)
        let warnings = rewriteRollouts(threads, newCwd: newPath.path)
        return CodexSessionMutationSummary(changedThreads: threads.count, rolloutWarnings: warnings)
    }

    func deleteProject(_ project: CodexSessionProject) throws -> CodexSessionMutationSummary {
        guard !project.isSystem else { throw CodexSessionOrganizerError.cannotDeleteUnassigned }
        try ensureCodexNotRunning()
        try fm.createDirectory(at: deletedProjectURL, withIntermediateDirectories: true)
        let threads = try readThreads(matchingCwd: project.path)
        try backupDatabaseIfNeeded()
        _ = try runSQLite(arguments: [
            stateDB.path,
            "UPDATE threads SET cwd = \(sqlQuote(deletedProjectURL.path)) WHERE cwd = \(sqlQuote(project.path));"
        ])
        removeSavedProject(path: project.path)
        let warnings = rewriteRollouts(threads, newCwd: deletedProjectURL.path)
        return CodexSessionMutationSummary(changedThreads: threads.count, rolloutWarnings: warnings)
    }

    func quitCodexApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Codex\" to quit"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    func openCodexApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Codex"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    private func readThreads(matchingCwd cwd: String) throws -> [CodexSessionThread] {
        let sql = """
        SELECT id,
               CASE WHEN title != '' THEN title ELSE first_user_message END AS title,
               cwd,
               model_provider AS modelProvider,
               COALESCE(updated_at_ms, updated_at * 1000) AS updatedAtMs,
               archived,
               rollout_path AS rolloutPath
        FROM threads
        WHERE cwd = \(sqlQuote(cwd))
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC, id DESC;
        """
        let output = try runSQLite(arguments: ["-json", stateDB.path, sql])
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let rows = try JSONDecoder().decode([SQLiteThreadRow].self, from: Data(output.utf8))
        return rows.map {
            CodexSessionThread(
                id: $0.id,
                title: $0.title ?? "",
                cwd: $0.cwd,
                modelProvider: $0.modelProvider,
                updatedAtMs: $0.updatedAtMs ?? 0,
                archived: $0.archived != 0,
                rolloutPath: $0.rolloutPath
            )
        }
    }

    private func rewriteRollouts(_ threads: [CodexSessionThread], newCwd: String) -> Int {
        var warnings = 0
        for thread in threads where !thread.rolloutPath.isEmpty {
            do {
                try rewriteRolloutCwd(atPath: thread.rolloutPath, newCwd: newCwd)
            } catch {
                warnings += 1
            }
        }
        return warnings
    }

    private func rewriteRolloutCwd(atPath path: String, newCwd: String) throws {
        guard fm.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let firstLine = try readFirstLine(from: url)
        guard !firstLine.isEmpty else { return }

        guard var object = try JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              var payload = object["payload"] as? [String: Any] else {
            return
        }
        payload["cwd"] = newCwd
        object["payload"] = payload

        let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        var newLine = jsonData
        let paddedLength = firstLine.count
        if jsonData.count + 1 <= paddedLength {
            let pad = paddedLength - jsonData.count - 1
            if pad > 0 { newLine.append(Data(repeating: 0x20, count: pad)) }
            newLine.append(0x0A)
            backupRolloutFirstLine(path: path, firstLine: firstLine)
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: newLine)
            return
        }

        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size < 100 * 1024 * 1024 else {
            throw CodexSessionOrganizerError.rolloutRewriteWouldBeExpensive(path)
        }
        backupRolloutFirstLine(path: path, firstLine: firstLine)
        try rewriteRolloutFile(url: url, firstLineLength: UInt64(firstLine.count), newJSONLine: jsonData)
    }

    private func readFirstLine(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return line }
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[...newlineIndex])
                return line
            }
            line.append(chunk)
            if line.count > 5 * 1024 * 1024 {
                throw CodexSessionOrganizerError.rolloutFirstLineTooLarge(url.path)
            }
        }
    }

    private func rewriteRolloutFile(url: URL, firstLineLength: UInt64, newJSONLine: Data) throws {
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).cxpod.tmp")
        fm.createFile(atPath: tmpURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: url)
        let output = try FileHandle(forWritingTo: tmpURL)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: newJSONLine)
        try output.write(contentsOf: Data([0x0A]))
        try input.seek(toOffset: firstLineLength)
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
    }

    private func backupDatabaseIfNeeded() throws {
        _ = try backupRoot()
    }

    private func backupRoot() throws -> URL {
        if let backupRootURL { return backupRootURL }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let root = codexHome
            .appendingPathComponent("cxpod-organizer-backups", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let dbBackupPath = root.appendingPathComponent("state_5.sqlite").path
        _ = try runSQLite(arguments: [stateDB.path, ".backup \(sqlQuote(dbBackupPath))"])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbBackupPath)
        if fm.fileExists(atPath: globalStateURL.path) {
            let globalStateBackup = root.appendingPathComponent(".codex-global-state.json")
            try? fm.copyItem(at: globalStateURL, to: globalStateBackup)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: globalStateBackup.path)
        }
        backupRootURL = root
        return root
    }

    private func backupRolloutFirstLine(path: String, firstLine: Data) {
        guard let root = try? backupRoot() else { return }
        let rolloutDir = root.appendingPathComponent("rollout-first-lines", isDirectory: true)
        try? fm.createDirectory(at: rolloutDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rolloutDir.path)
        let name = UUID().uuidString + ".jsonl"
        let lineURL = rolloutDir.appendingPathComponent(name)
        try? firstLine.write(to: lineURL)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lineURL.path)
        let manifestLine = "\(name)\t\(path)\n"
        let manifestURL = root.appendingPathComponent("rollout-manifest.tsv")
        if fm.fileExists(atPath: manifestURL.path),
           let handle = try? FileHandle(forWritingTo: manifestURL) {
            handle.seekToEndOfFile()
            if let data = manifestLine.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? manifestLine.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    private func ensureCodexNotRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "/Applications/Codex.app/"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        if process.terminationStatus == 0 {
            throw CodexSessionOrganizerError.codexRunning
        }
    }

    private func runSQLite(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CodexSessionOrganizerError.sqliteFailed(error.localizedDescription)
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CodexSessionOrganizerError.sqliteFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func loadSavedProjects() -> SavedCodexProjectsConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(SavedCodexProjectsConfig.self, from: data) else {
            return SavedCodexProjectsConfig(projects: [])
        }
        return config
    }

    private func loadCodexAppSidebarState() -> CodexAppSidebarState {
        guard let state = loadCodexGlobalState() else { return .empty }
        let projectOrder = state["project-order"] as? [String] ?? []
        let projectlessThreadIDs = Set(state["projectless-thread-ids"] as? [String] ?? [])
        let threadWorkspaceRootHints = state["thread-workspace-root-hints"] as? [String: String] ?? [:]
        return CodexAppSidebarState(
            projectOrder: projectOrder,
            projectlessThreadIDs: projectlessThreadIDs,
            threadWorkspaceRootHints: threadWorkspaceRootHints
        )
    }

    private func loadCodexGlobalState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: globalStateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func updateCodexGlobalState(_ mutate: (inout [String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: globalStateURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        mutate(&object)
        guard let newData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return
        }
        try? newData.write(to: globalStateURL, options: .atomic)
    }

    private func displayProjectPath(for thread: CodexSessionThread, saved: SavedCodexProjectsConfig, sidebarState: CodexAppSidebarState) -> String {
        if thread.cwd == unassignedURL.path || thread.cwd == deletedProjectURL.path {
            return thread.cwd
        }
        if sidebarState.projectlessThreadIDs.contains(thread.id) || isCodexGeneratedSessionPath(thread.cwd) {
            return unassignedURL.path
        }
        let visiblePaths = Set(sidebarState.projectOrder).union(saved.projects.map(\.path))
        if visiblePaths.contains(thread.cwd) {
            return thread.cwd
        }
        return unassignedURL.path
    }

    private func isCodexGeneratedSessionPath(_ path: String) -> Bool {
        let codexDocumentsRoot = home.appendingPathComponent("Documents/Codex", isDirectory: true).path
        return path == codexDocumentsRoot || path.hasPrefix(codexDocumentsRoot + "/")
    }

    private func threadWorkspaceRootHint(for thread: CodexSessionThread) -> String {
        if isCodexGeneratedSessionPath(thread.cwd) {
            return home.appendingPathComponent("Documents/Codex", isDirectory: true).path
        }
        return thread.cwd
    }

    private func markThreadProjectless(threadID: String, workspaceRootHint: String) {
        updateCodexGlobalState { state in
            var ids = state["projectless-thread-ids"] as? [String] ?? []
            if !ids.contains(threadID) { ids.append(threadID) }
            state["projectless-thread-ids"] = ids

            var hints = state["thread-workspace-root-hints"] as? [String: String] ?? [:]
            hints[threadID] = workspaceRootHint
            state["thread-workspace-root-hints"] = hints
        }
    }

    private func markThreadAssigned(threadID: String, projectPath: String) {
        updateCodexGlobalState { state in
            var ids = state["projectless-thread-ids"] as? [String] ?? []
            ids.removeAll { $0 == threadID }
            state["projectless-thread-ids"] = ids

            var hints = state["thread-workspace-root-hints"] as? [String: String] ?? [:]
            hints.removeValue(forKey: threadID)
            state["thread-workspace-root-hints"] = hints

            var order = state["project-order"] as? [String] ?? []
            if projectPath != unassignedURL.path && !order.contains(projectPath) {
                order.append(projectPath)
            }
            state["project-order"] = order
        }
    }

    private func saveProjects(_ config: SavedCodexProjectsConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }

    private func upsertSavedProject(path: String, name: String) {
        var config = loadSavedProjects()
        config.projects.removeAll { $0.path == path }
        config.projects.append(SavedCodexProject(path: path, name: name))
        config.projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveProjects(config)
    }

    private func removeSavedProject(path: String) {
        var config = loadSavedProjects()
        config.projects.removeAll { $0.path == path }
        saveProjects(config)
    }

    private func normalizedProjectName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func uniqueManagedPath(for name: String, allowingExistingPath: String? = nil) -> URL {
        let base = managedRoot.appendingPathComponent(name, isDirectory: true)
        if let allowingExistingPath, base.path == allowingExistingPath { return base }
        if !fm.fileExists(atPath: base.path) { return base }
        for index in 2...999 {
            let candidate = managedRoot.appendingPathComponent("\(name)-\(index)", isDirectory: true)
            if candidate.path == allowingExistingPath || !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return managedRoot.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    }

    private func defaultProjectName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func systemProjectName(path: String) -> String? {
        if path == unassignedURL.path { return "未归类" }
        if path == deletedProjectURL.path { return "待整理-原项目已删除" }
        return nil
    }

    private func sqlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

final class CodexSessionOrganizerViewModel: ObservableObject {
    @Published var projects: [CodexSessionProject] = []
    @Published var threads: [CodexSessionThread] = []
    @Published var selectedProjectID: String?
    @Published var includeArchived = false
    @Published var searchText = ""
    @Published var statusText = "重启 Codex.app 后生效"
    @Published var errorText: String?
    @Published var selectedThreadIDs = Set<String>()
    @Published var pendingMoves: [String: String] = [:]
    @Published var cutThreadIDs = Set<String>()

    private let organizer = CodexSessionOrganizer()
    private var originalThreads: [CodexSessionThread] = []

    var selectedProject: CodexSessionProject? {
        projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    var selectedThreads: [CodexSessionThread] {
        guard let project = selectedProject else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return threads.filter { thread in
            guard thread.cwd == project.path else { return false }
            guard !query.isEmpty else { return true }
            return thread.displayTitle.lowercased().contains(query)
                || thread.modelProvider.lowercased().contains(query)
                || thread.id.lowercased().contains(query)
        }
    }

    func reload() {
        do {
            let newThreads = try organizer.readThreads(includeArchived: includeArchived)
            pendingMoves = organizer.pendingMoves()
            originalThreads = newThreads
            let displayThreads = organizer.threadsByApplyingPendingMoves(newThreads)
            let newProjects = organizer.projects(from: displayThreads)
            threads = displayThreads
            projects = newProjects
            if selectedProjectID == nil || !newProjects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = newProjects.first?.id
            }
            selectedThreadIDs = selectedThreadIDs.filter { id in displayThreads.contains { $0.id == id } }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func createProjectFromPrompt() {
        guard let name = prompt(title: "新建项目", message: "输入项目名称", defaultValue: "") else { return }
        do {
            let project = try organizer.createProject(named: name)
            reload()
            selectedProjectID = project.id
            statusText = "已新建项目：\(project.name)"
        } catch {
            errorText = error.localizedDescription
        }
    }

    func renameSelectedProject() {
        guard let project = selectedProject else { return }
        guard let name = prompt(title: "重命名项目", message: "会话会移动到新的 Codex 分组路径", defaultValue: project.name) else { return }
        do {
            let summary = try organizer.renameProject(project, to: name)
            reload()
            statusText = summaryText(prefix: "已重命名", summary: summary)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func deleteSelectedProject() {
        guard let project = selectedProject else { return }
        let alert = NSAlert()
        alert.messageText = "删除项目？"
        alert.informativeText = "只删除这个分组归属，不删除会话，也不删除真实文件夹。项目内会话会移到“待整理-原项目已删除”。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除项目")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let movingIDs = threads.filter { $0.cwd == project.path }.map(\.id)
        for id in movingIDs { pendingMoves[id] = organizer.deletedProjectPath }
        organizer.savePendingMoves(pendingMoves)
        reload()
        selectedProjectID = organizer.deletedProjectPath
        statusText = "已放入待同步：\(movingIDs.count) 个会话"
    }

    func moveThread(id: String, to project: CodexSessionProject) {
        guard let thread = threads.first(where: { $0.id == id }), thread.cwd != project.path else { return }
        pendingMoves[id] = project.path
        organizer.savePendingMoves(pendingMoves)
        reload()
        selectedProjectID = project.id
        statusText = "已放入待同步：1 个会话"
    }

    func moveThreads(ids: [String], to project: CodexSessionProject) {
        let idSet = Set(ids)
        let moving = threads.filter { idSet.contains($0.id) && $0.cwd != project.path }
        guard !moving.isEmpty else { return }
        for thread in moving { pendingMoves[thread.id] = project.path }
        organizer.savePendingMoves(pendingMoves)
        reload()
        selectedProjectID = project.id
        selectedThreadIDs.removeAll()
        cutThreadIDs.subtract(idSet)
        statusText = "已放入待同步：\(moving.count) 个会话"
    }

    func selectProject(_ project: CodexSessionProject) {
        selectedProjectID = project.id
        selectedThreadIDs.removeAll()
    }

    func setThreadSelection(_ id: String, selected: Bool) {
        if selected {
            selectedThreadIDs.insert(id)
        } else {
            selectedThreadIDs.remove(id)
        }
    }

    func moveSelectedThreads(to project: CodexSessionProject) {
        let moving = threads.filter { selectedThreadIDs.contains($0.id) && $0.cwd != project.path }
        guard !moving.isEmpty else { return }
        for thread in moving { pendingMoves[thread.id] = project.path }
        organizer.savePendingMoves(pendingMoves)
        reload()
        selectedProjectID = project.id
        selectedThreadIDs.removeAll()
        statusText = "已放入待同步：\(moving.count) 个会话"
    }

    func selectAllVisibleThreads() {
        selectedThreadIDs = Set(selectedThreads.map(\.id))
        statusText = "已选择 \(selectedThreadIDs.count) 个会话"
    }

    func clearThreadSelection() {
        selectedThreadIDs.removeAll()
        statusText = "已取消选择"
    }

    func moveSelectedThreadsToUnassigned() {
        guard let unassigned = projects.first(where: { $0.path == organizer.unassignedPath }) else { return }
        moveSelectedThreads(to: unassigned)
    }

    func cutSelectedThreads() {
        cutThreadIDs = selectedThreadIDs
        statusText = cutThreadIDs.isEmpty ? "没有选中会话" : "已剪切 \(cutThreadIDs.count) 个会话"
    }

    func pasteCutThreadsIntoSelectedProject() {
        guard let project = selectedProject, !cutThreadIDs.isEmpty else { return }
        moveThreads(ids: Array(cutThreadIDs), to: project)
    }

    func dragPayload(for thread: CodexSessionThread) -> String {
        let ids: [String]
        if selectedThreadIDs.contains(thread.id), !selectedThreadIDs.isEmpty {
            ids = selectedThreads.map(\.id).filter { selectedThreadIDs.contains($0) }
        } else {
            ids = [thread.id]
        }
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else {
            return thread.id
        }
        return json
    }

    func applyPendingMoves() {
        do {
            let summary = try organizer.applyPendingMoves(pendingMoves, originalThreads: originalThreads)
            pendingMoves.removeAll()
            reload()
            statusText = summaryText(prefix: "已同步到 Codex", summary: summary)
        } catch {
            showApplyBlockedAlert(message: error.localizedDescription)
            errorText = error.localizedDescription
        }
    }

    func discardPendingMoves() {
        pendingMoves.removeAll()
        organizer.savePendingMoves([:])
        reload()
        statusText = "已撤销待同步改动"
    }

    func quitCodexApp() {
        organizer.quitCodexApp()
        statusText = "已请求退出 Codex.app"
    }

    func openCodexApp() {
        organizer.openCodexApp()
        statusText = "已请求打开 Codex.app"
    }

    private func summaryText(prefix: String, summary: CodexSessionMutationSummary) -> String {
        if summary.rolloutWarnings > 0 {
            return "\(prefix)：\(summary.changedThreads) 个，会话索引已更新，\(summary.rolloutWarnings) 个 rollout 元数据跳过"
        }
        return "\(prefix)：\(summary.changedThreads) 个"
    }

    private func showApplyBlockedAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "暂未同步到 Codex"
        alert.informativeText = "\(message)\n\n你可以继续整理，改动会保留为待同步；退出 Codex.app 后再点“同步到 Codex”。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func prompt(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }
}

struct CodexSessionOrganizerView: View {
    @StateObject private var vm = CodexSessionOrganizerViewModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            sessionList
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { vm.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .codexOrganizerSelectAll)) { _ in
            vm.selectAllVisibleThreads()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexOrganizerCut)) { _ in
            vm.cutSelectedThreads()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexOrganizerPaste)) { _ in
            vm.pasteCutThreadsIntoSelectedProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexOrganizerClearSelection)) { _ in
            vm.clearThreadSelection()
        }
        .background(
            CodexOrganizerKeyboardHandler(
                onSelectAll: { vm.selectAllVisibleThreads() },
                onCut: { vm.cutSelectedThreads() },
                onPaste: { vm.pasteCutThreadsIntoSelectedProject() },
                onClearSelection: { vm.clearThreadSelection() }
            )
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("项目").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { vm.createProjectFromPrompt() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("新建项目")
                Button(action: { vm.renameSelectedProject() }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .disabled(vm.selectedProject?.isSystem ?? true)
                .help("重命名项目")
                Button(action: { vm.deleteSelectedProject() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(vm.selectedProject?.isSystem ?? true)
                .help("删除项目")
            }
            Text("删除项目会移入“待整理-原项目已删除”")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.projects) { project in
                        CodexProjectDropRow(
                            project: project,
                            isSelected: project.id == vm.selectedProjectID,
                            onSelect: { vm.selectProject(project) },
                            onDropThreads: { threadIDs in vm.moveThreads(ids: threadIDs, to: project) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionHeader

            if let error = vm.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.selectedThreads) { thread in
                        CodexThreadRow(
                            thread: thread,
                            isSelected: vm.selectedThreadIDs.contains(thread.id),
                            isPending: vm.pendingMoves[thread.id] != nil,
                            isCut: vm.cutThreadIDs.contains(thread.id),
                            dragPayload: vm.dragPayload(for: thread),
                            onSelectionChange: { selected in
                                vm.setThreadSelection(thread.id, selected: selected)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .contextMenu {
                Button("全选当前列表") {
                    vm.selectAllVisibleThreads()
                }
                Button("取消选择") {
                    vm.clearThreadSelection()
                }
                .disabled(vm.selectedThreadIDs.isEmpty)
                Button("移到未归类") {
                    vm.moveSelectedThreadsToUnassigned()
                }
                .disabled(vm.selectedThreadIDs.isEmpty)
                Button("剪切") {
                    vm.cutSelectedThreads()
                }
                .disabled(vm.selectedThreadIDs.isEmpty)
                Button("粘贴到当前项目") {
                    vm.pasteCutThreadsIntoSelectedProject()
                }
                .disabled(vm.cutThreadIDs.isEmpty)
                Menu("移动到") {
                    ForEach(vm.projects.filter { $0.id != vm.selectedProjectID }) { project in
                        Button(project.name) {
                            vm.moveSelectedThreads(to: project)
                        }
                    }
                }
                .disabled(vm.selectedThreadIDs.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.selectedProject?.name ?? "会话")
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(vm.statusText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    countBadge("\(vm.selectedThreads.count) 个会话", color: .secondary)
                    if !vm.selectedThreadIDs.isEmpty {
                        countBadge("已选 \(vm.selectedThreadIDs.count)", color: .accentColor)
                    }
                    if !vm.cutThreadIDs.isEmpty {
                        countBadge("剪切 \(vm.cutThreadIDs.count)", color: .secondary)
                    }
                    if !vm.pendingMoves.isEmpty {
                        countBadge("待同步 \(vm.pendingMoves.count)", color: .orange)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("全选") { vm.selectAllVisibleThreads() }
                    .disabled(vm.selectedThreads.isEmpty)
                Button("取消选择") { vm.clearThreadSelection() }
                    .disabled(vm.selectedThreadIDs.isEmpty)
                Button("剪切") { vm.cutSelectedThreads() }
                    .disabled(vm.selectedThreadIDs.isEmpty)
                Button("粘贴到此项目") { vm.pasteCutThreadsIntoSelectedProject() }
                    .disabled(vm.cutThreadIDs.isEmpty)

                Menu("移动到") {
                    ForEach(vm.projects.filter { $0.id != vm.selectedProjectID }) { project in
                        Button(project.name) {
                            vm.moveSelectedThreads(to: project)
                        }
                    }
                }
                .disabled(vm.selectedThreadIDs.isEmpty)

                Button("移到未归类") { vm.moveSelectedThreadsToUnassigned() }
                    .disabled(vm.selectedThreadIDs.isEmpty)

                Spacer(minLength: 8)
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                TextField("搜索会话", text: $vm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)

                Toggle("显示归档", isOn: Binding(
                    get: { vm.includeArchived },
                    set: { vm.includeArchived = $0; vm.reload() }
                ))
                .toggleStyle(.checkbox)

                Button(action: { vm.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")

                Spacer(minLength: 8)

                Button("同步到 Codex") { vm.applyPendingMoves() }
                    .disabled(vm.pendingMoves.isEmpty)
                Button("撤销待同步") { vm.discardPendingMoves() }
                    .disabled(vm.pendingMoves.isEmpty)
                Button(action: { vm.quitCodexApp() }) {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("退出 Codex.app")
                Button(action: { vm.openCodexApp() }) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .help("打开 Codex.app")
            }
            .controlSize(.small)
        }
    }

    private func countBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct CodexProjectDropRow: View {
    let project: CodexSessionProject
    let isSelected: Bool
    let onSelect: () -> Void
    let onDropThreads: ([String]) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.isUnassigned ? "tray" : "folder")
                .foregroundColor(project.isUnassigned ? .secondary : .accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(project.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(project.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onDrop(of: [UTType.text], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                let value: String?
                if let text = item as? String {
                    value = text
                } else if let text = item as? NSString {
                    value = text as String
                } else if let data = item as? Data {
                    value = String(data: data, encoding: .utf8)
                } else {
                    value = nil
                }
                if let value {
                    DispatchQueue.main.async { onDropThreads(parseDraggedThreadIDs(value)) }
                }
            }
            return true
        }
    }

    private var rowBackground: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.18) }
        if isSelected { return Color.accentColor.opacity(0.12) }
        return Color.clear
    }

    private func parseDraggedThreadIDs(_ value: String) -> [String] {
        if let data = value.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids
        }
        return [value]
    }
}

private struct CodexThreadRow: View {
    let thread: CodexSessionThread
    let isSelected: Bool
    let isPending: Bool
    let isCut: Bool
    let dragPayload: String
    let onSelectionChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { onSelectionChange(!isSelected) }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "取消选择" : "选择")

            Image(systemName: thread.archived ? "archivebox" : "bubble.left.and.bubble.right")
                .foregroundColor(thread.archived ? .secondary : .accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(thread.modelProvider)
                    Text(formatDate(thread.updatedAtMs))
                    Text(thread.id)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if isPending {
                    Text("待同步")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                if isCut {
                    Text("已剪切")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectionChange(!isSelected)
        }
        .opacity(isCut ? 0.55 : 1)
        .onDrag {
            NSItemProvider(object: dragPayload as NSString)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        return Color.clear
    }

    private func formatDate(_ ms: Int64) -> String {
        guard ms > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct CodexOrganizerKeyboardHandler: NSViewRepresentable {
    let onSelectAll: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onClearSelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelectAll: onSelectAll,
            onCut: onCut,
            onPaste: onPaste,
            onClearSelection: onClearSelection
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onSelectAll = onSelectAll
        context.coordinator.onCut = onCut
        context.coordinator.onPaste = onPaste
        context.coordinator.onClearSelection = onClearSelection
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var onSelectAll: () -> Void
        var onCut: () -> Void
        var onPaste: () -> Void
        var onClearSelection: () -> Void
        private var monitor: Any?

        init(
            onSelectAll: @escaping () -> Void,
            onCut: @escaping () -> Void,
            onPaste: @escaping () -> Void,
            onClearSelection: @escaping () -> Void
        ) {
            self.onSelectAll = onSelectAll
            self.onCut = onCut
            self.onPaste = onPaste
            self.onClearSelection = onClearSelection
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window, event.window === window, NSApp.keyWindow === window else {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if key == "\u{1b}" {
                onClearSelection()
                return nil
            }

            guard flags.contains(.command) else { return event }
            switch key {
            case "a":
                onSelectAll()
                return nil
            case "x":
                onCut()
                return nil
            case "v":
                onPaste()
                return nil
            default:
                return event
            }
        }
    }
}
