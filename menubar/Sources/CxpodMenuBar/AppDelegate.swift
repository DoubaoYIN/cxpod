import AppKit

extension Notification.Name {
    static let codexOrganizerSelectAll = Notification.Name("codexOrganizerSelectAll")
    static let codexOrganizerCut = Notification.Name("codexOrganizerCut")
    static let codexOrganizerPaste = Notification.Name("codexOrganizerPaste")
    static let codexOrganizerClearSelection = Notification.Name("codexOrganizerClearSelection")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        setupMainMenu()
        statusController = StatusController()
        statusController?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",   action: #selector(organizerCut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(organizerPaste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(organizerSelectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Cancel Selection", action: #selector(organizerClearSelection(_:)), keyEquivalent: "\u{1b}")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func organizerSelectAll(_ sender: Any?) {
        NotificationCenter.default.post(name: .codexOrganizerSelectAll, object: nil)
    }

    @objc private func organizerCut(_ sender: Any?) {
        NotificationCenter.default.post(name: .codexOrganizerCut, object: nil)
    }

    @objc private func organizerPaste(_ sender: Any?) {
        NotificationCenter.default.post(name: .codexOrganizerPaste, object: nil)
    }

    @objc private func organizerClearSelection(_ sender: Any?) {
        NotificationCenter.default.post(name: .codexOrganizerClearSelection, object: nil)
    }
}
