#!/usr/bin/env bash
# Verify that the organizer mirrors Codex App's project-order sidebar model.
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/cxpod-organizer-sidebar-check.$$"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

cat > "$TMP_DIR/NotificationNames.swift" <<'SWIFT'
import Foundation

extension Notification.Name {
    static let codexOrganizerSelectAll = Notification.Name("codexOrganizerSelectAll")
    static let codexOrganizerCut = Notification.Name("codexOrganizerCut")
    static let codexOrganizerPaste = Notification.Name("codexOrganizerPaste")
    static let codexOrganizerClearSelection = Notification.Name("codexOrganizerClearSelection")
}
SWIFT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sidebar check failed: \(message)\n".utf8))
    exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
    try data.write(to: url)
}

func makeHome(globalState: [String: Any]) throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("cxpod-organizer-sidebar-\(UUID().uuidString)", isDirectory: true)
    let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try writeJSON(globalState, to: codexHome.appendingPathComponent(".codex-global-state.json"))
    return home
}

func writeSavedConfig(home: URL, pendingThreadProjects: [String: String]) throws {
    let configURL = home.appendingPathComponent(".cxpod/codex-session-projects.json")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeJSON([
        "pendingThreadProjects": pendingThreadProjects,
        "projects": []
    ], to: configURL)
}

func makeThread(id: String, cwd: String, updatedAtMs: Int64 = 0) -> CodexSessionThread {
    CodexSessionThread(
        id: id,
        title: "",
        firstUserMessage: "测试会话 \(id)",
        preview: "",
        cwd: cwd,
        modelProvider: "test",
        updatedAtMs: updatedAtMs,
        archived: false,
        rolloutPath: ""
    )
}

func checkProjectOrderFiltering() throws {
    let projectPath = "/tmp/cxpod-tests/Projects/cxpod"
    let hiddenProjectPath = "/tmp/cxpod-tests/Projects/not-in-codex-sidebar"
    let home = try makeHome(globalState: [
        "project-order": [projectPath],
        "projectless-thread-ids": ["projectless"],
        "thread-workspace-root-hints": [:]
    ])
    defer { try? FileManager.default.removeItem(at: home) }

    let organizer = CodexSessionOrganizer(home: home, checksCodexRunning: false)
    let unassignedPath = organizer.unassignedPath
    let codexDocumentPath = home.appendingPathComponent("Documents/Codex/2026-06-29/random-session").path

    let displayedThreads = organizer.threadsByApplyingPendingMoves([
        makeThread(id: "known", cwd: projectPath, updatedAtMs: 40),
        makeThread(id: "codex-document", cwd: codexDocumentPath, updatedAtMs: 30),
        makeThread(id: "hidden", cwd: hiddenProjectPath, updatedAtMs: 20),
        makeThread(id: "projectless", cwd: projectPath, updatedAtMs: 10)
    ])
    let cwdByID = Dictionary(uniqueKeysWithValues: displayedThreads.map { ($0.id, $0.cwd) })
    expect(cwdByID["known"] == projectPath, "Codex project-order path should stay visible")
    expect(cwdByID["codex-document"] == unassignedPath, "Documents/Codex cwd should become unassigned")
    expect(cwdByID["hidden"] == unassignedPath, "cwd outside project-order should become unassigned")
    expect(cwdByID["projectless"] == unassignedPath, "projectless thread should become unassigned")

    let projects = organizer.projects(from: displayedThreads)
    let projectPaths = Set(projects.map(\.path))
    expect(projectPaths.contains(projectPath), "project-order path missing")
    expect(projectPaths.contains(unassignedPath), "unassigned system project missing")
    expect(!projectPaths.contains(codexDocumentPath), "Documents/Codex cwd leaked into sidebar")
    expect(!projectPaths.contains(hiddenProjectPath), "non-Codex project cwd leaked into sidebar")
    expect(projects.first { $0.path == unassignedPath }?.count == 3, "unassigned count mismatch")
    expect(projects.first { $0.path == projectPath }?.count == 1, "project count mismatch")
}

func checkPendingMovesOverrideDisplay() throws {
    let targetProjectPath = "/tmp/cxpod-tests/Projects/ccpod"
    let home = try makeHome(globalState: [
        "project-order": [targetProjectPath],
        "projectless-thread-ids": [],
        "thread-workspace-root-hints": [:]
    ])
    defer { try? FileManager.default.removeItem(at: home) }

    let organizer = CodexSessionOrganizer(home: home, checksCodexRunning: false)
    let unassignedPath = organizer.unassignedPath
    try writeSavedConfig(home: home, pendingThreadProjects: [
        "move-to-project": targetProjectPath,
        "move-to-unassigned": unassignedPath
    ])

    let displayedThreads = organizer.threadsByApplyingPendingMoves([
        makeThread(id: "move-to-project", cwd: home.appendingPathComponent("Documents/Codex/2026-06-29/tmp").path),
        makeThread(id: "move-to-unassigned", cwd: targetProjectPath)
    ])
    let cwdByID = Dictionary(uniqueKeysWithValues: displayedThreads.map { ($0.id, $0.cwd) })
    expect(cwdByID["move-to-project"] == targetProjectPath, "pending project move not reflected")
    expect(cwdByID["move-to-unassigned"] == unassignedPath, "pending unassigned move not reflected")

    let projects = organizer.projects(from: displayedThreads)
    expect(projects.first { $0.path == targetProjectPath }?.count == 1, "pending project count mismatch")
    expect(projects.first { $0.path == unassignedPath }?.count == 1, "pending unassigned count mismatch")
}

do {
    try checkProjectOrderFiltering()
    try checkPendingMovesOverrideDisplay()
    print("ok: organizer sidebar project-order check passed")
} catch {
    fail(String(describing: error))
}
SWIFT

swiftc \
  "$ROOT_DIR/menubar/Sources/CxpodMenuBar/CodexSessionOrganizer.swift" \
  "$TMP_DIR/NotificationNames.swift" \
  "$TMP_DIR/main.swift" \
  -o "$TMP_DIR/sidebar-check"

"$TMP_DIR/sidebar-check"
