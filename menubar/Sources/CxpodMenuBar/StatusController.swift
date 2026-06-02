import AppKit
import SwiftUI

final class StatusController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private let menuBarIcon = StatusController.makeMenuBarIcon()
    private let sessionManager = SessionManager()
    private let providerManager = ProviderManager()
    private let projectManager = ProjectManager()
    private var popover: NSPopover?
    private let vm = PopoverViewModel()
    private var addProviderWindow: NSWindow?
    private var codexSessionOrganizerWindow: NSWindow?
    private var balanceAutoRefreshTimer: Timer?
    private var balanceAutoRefreshEnabled = false

    private let initialBalanceAutoRefreshDelay: TimeInterval = 5 * 60
    private let balanceAutoRefreshInterval: TimeInterval = 60 * 60
    private var isOrganizerDebugMode: Bool {
        CommandLine.arguments.contains("--organizer")
    }

    func start() {
        NSLog("[CxPod] StatusController.start()")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        NSLog("[CxPod] statusItem created, button=%@", String(describing: item.button))
        item.button?.image = menuBarIcon
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "CxPod"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        sessionManager.onChange = { [weak self] in
            DispatchQueue.main.async { self?.updateBadge(); self?.refreshVM() }
        }
        sessionManager.start()

        providerManager.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshVM() }
        }
        providerManager.start()

        projectManager.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshVM() }
        }
        projectManager.start()

        vm.onLaunch = { [weak self] provider, project, terminal in
            self?.popover?.close()
            self?.doLaunch(provider: provider, project: project, terminalName: terminal)
        }
        vm.onSwitch = { [weak self] session, target in
            self?.popover?.close()
            self?.doSwitch(session: session, target: target)
        }
        vm.onClose = { [weak self] session in self?.doClose(session: session) }
        vm.onQuit = { NSApp.terminate(nil) }
        vm.onShowAddProvider = { [weak self] in
            self?.popover?.close(); self?.showAddProviderWindow()
        }
        vm.onAddProject = { [weak self] in
            self?.popover?.close(); self?.showAddProjectDialog()
        }
        vm.onCodexAppSwitch = { [weak self] target in
            self?.popover?.close()
            self?.doCodexAppSwitch(target: target)
        }
        vm.onShowCodexSessionOrganizer = { [weak self] in
            self?.popover?.close()
            self?.showCodexSessionOrganizerWindow()
        }
        BalanceService.shared.onUpdate = { [weak self] provider, info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.vm.balances[provider] = info
            }
        }
        updateBadge()
        startBalanceAutoRefresh()

        if isOrganizerDebugMode {
            DispatchQueue.main.async { [weak self] in
                self?.showCodexSessionOrganizerWindow()
            }
        }
    }

    func stop() {
        stopBalanceAutoRefresh()
        sessionManager.stop(); providerManager.stop(); projectManager.stop()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    @objc private func togglePopover() {
        NSLog("[CxPod] togglePopover called")
        if let popover = popover, popover.isShown {
            popover.close(); return
        }
        refreshVM()
        let pop = NSPopover()
        pop.behavior = .transient; pop.animates = true
        let hosting = NSHostingController(rootView: PopoverContentView(vm: vm))
        let size = hosting.view.fittingSize
        pop.contentSize = NSSize(width: max(size.width, 320), height: size.height)
        pop.contentViewController = hosting
        popover = pop
        if let button = statusItem?.button {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refreshVM() {
        vm.refresh(providerManager: providerManager, projectManager: projectManager, sessionManager: sessionManager)
    }

    private func startBalanceAutoRefresh() {
        stopBalanceAutoRefresh()
        balanceAutoRefreshEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + initialBalanceAutoRefreshDelay) { [weak self] in
            guard let self, self.balanceAutoRefreshEnabled else { return }
            self.refreshActiveBalances()
        }
        let timer = Timer(timeInterval: balanceAutoRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshActiveBalances()
        }
        RunLoop.main.add(timer, forMode: .common)
        balanceAutoRefreshTimer = timer
    }

    private func stopBalanceAutoRefresh() {
        balanceAutoRefreshEnabled = false
        balanceAutoRefreshTimer?.invalidate()
        balanceAutoRefreshTimer = nil
    }

    private func refreshActiveBalances() {
        BalanceService.shared.refreshKnown(providers: activeBalanceProviders())
    }

    private func activeBalanceProviders() -> [String] {
        var providers = Set<String>()
        if let current = providerManager.currentProvider(), !current.isEmpty {
            providers.insert(current)
        }
        if let currentCodexAppProvider = providerManager.currentCodexAppProvider(), !currentCodexAppProvider.isEmpty {
            providers.insert(currentCodexAppProvider)
        }
        for session in sessionManager.sessions where !session.provider.isEmpty {
            providers.insert(session.provider)
        }
        providers.remove("openai")
        return Array(providers).sorted()
    }

    private func updateBadge() {
        let sessions = sessionManager.sessions
        let tooltip: String
        if sessions.isEmpty { tooltip = "CxPod" }
        else if sessions.count == 1 {
            let s = sessions[0]
            tooltip = "CxPod #\(s.sessionNumber) \(s.provider) · \(s.projectName)"
        } else {
            let nums = sessions.map { "#\($0.sessionNumber)" }.joined(separator: " ")
            tooltip = "CxPod \(sessions.count) 个会话 · \(nums)"
        }
        statusItem?.button?.image = menuBarIcon
        statusItem?.button?.toolTip = tooltip
    }

    private static func makeMenuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let str = NSAttributedString(string: "cx", attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: (size.width - strSize.width) / 2, y: (size.height - strSize.height) / 2))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func showAddProviderWindow() {
        if let w = addProviderWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let view = AddProviderView(onComplete: { [weak self] in
            self?.providerManager.reload(); self?.refreshVM(); self?.addProviderWindow?.close()
        })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "添加线路"; window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 340, height: 400)); window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        addProviderWindow = window
    }

    private func showAddProjectDialog() {
        let panel = NSOpenPanel()
        panel.title = "选择项目目录"; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            projectManager.addManualProject(path: url.path); refreshVM()
        }
    }

    private func showCodexSessionOrganizerWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = codexSessionOrganizerWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: CodexSessionOrganizerView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "整理 Codex 会话"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.minSize = NSSize(width: 980, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        codexSessionOrganizerWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === codexSessionOrganizerWindow else { return }
        codexSessionOrganizerWindow = nil
        if !isOrganizerDebugMode {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func doLaunch(provider: String, project: String, terminalName: String) {
        let adapter = TerminalRegistry.shared.adapters.first { $0.name == terminalName }
            ?? TerminalRegistry.shared.defaultAdapter
        let cli = locateCLI("cxstart")
        let command = "\(shellQuote(cli)) -d \(shellQuote(project)) -p \(shellQuote(provider))"
        let projectName = (project as NSString).lastPathComponent
        let title = "cxpod · \(provider) · \(projectName)"
        DispatchQueue.global().async { [weak self] in
            do { try adapter.openNewWindow(command: command, title: title) }
            catch { DispatchQueue.main.async { self?.showError(error) } }
        }
    }

    private func doSwitch(session: SessionInfo, target: String) {
        runInBackground(executable: locateCLI("cxuse"),
                        arguments: ["--window", session.windowID, target])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sessionManager.reload(); self?.refreshVM()
        }
    }

    private func doCodexAppSwitch(target: String) {
        runInBackground(executable: locateCLI("cx-app-switch"), arguments: [target])
        // Refresh after Codex.app finishes restarting so currentCodexAppProvider updates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshVM()
        }
    }

    private func doClose(session: SessionInfo) {
        runInBackground(executable: locateCLI("cxstart"), arguments: ["--kill", session.windowID])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sessionManager.reload(); self?.refreshVM(); self?.updateBadge()
        }
    }

    private func locateCLI(_ name: String) -> String {
        let fm = FileManager.default; let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/\(name)").path,
            "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)",
            home.appendingPathComponent("Projects/cxpod/bin/\(name)").path,
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? name
    }

    private func runInBackground(executable: String, arguments: [String]) {
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit() }
            catch { DispatchQueue.main.async { self?.showError(error) } }
        }
    }

    private func showError(_ err: Error) {
        let alert = NSAlert()
        alert.messageText = "CxPod 操作失败"
        alert.informativeText = String(describing: err)
        alert.alertStyle = .warning; alert.runModal()
    }
}
