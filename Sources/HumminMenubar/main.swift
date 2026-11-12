import AppKit
import FleetCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store: FleetStore
    private var window: NSWindow?

    init(store: FleetStore) {
        self.store = store
        super.init()
    }

    func applicationDidFinishLaunching(_ _: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        if let button = statusItem.button {
            button.image = BirdIcon.statusBarIcon()
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let error = store.configError { log(error) }
        store.refresh(force: true) // once at launch; polling only runs while the window is visible
    }

    // ---- status item ---------------------------------------------------------------

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Hummin", action: #selector(openWindow), keyEquivalent: "").target = self
            let refresh = menu.addItem(withTitle: "Refresh All", action: #selector(refreshAll), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Hummin Menubar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleWindow()
        }
    }

    @objc private func openWindow() { showWindow() }
    @objc private func refreshAll() { store.refresh(force: true) }

    private func toggleWindow() {
        if let w = window, w.isVisible, w.isKeyWindow { w.close() } else { showWindow() }
    }

    // ---- window ----------------------------------------------------------------------

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: FleetView(store: store, onClose: { [weak self] in self?.window?.close() }))
        hosting.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.title = "Hummin"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 560, height: 700))
        w.contentMinSize = NSSize(width: 460, height: 420)
        w.center()
        w.setFrameAutosaveName("HumminFleetWindow")
        w.delegate = self
        return w
    }

    private func showWindow() {
        let w = window ?? makeWindow()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        store.startPolling()
    }

    func windowDidChangeOcclusionState(_ _: Notification) {
        guard let w = window else { return }
        if w.occlusionState.contains(.visible) { store.startPolling() } else { store.stopPolling() }
    }

    func windowWillClose(_ _: Notification) { store.stopPolling() }

    // ---- main menu (key equivalents in an accessory app) ------------------------------------

    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func mi(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("Hummin", [mi("Quit Hummin Menubar", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            mi("Undo", Selector(("undo:")), "z"),
            mi("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            mi("Cut", #selector(NSText.cut(_:)), "x"),
            mi("Copy", #selector(NSText.copy(_:)), "c"),
            mi("Paste", #selector(NSText.paste(_:)), "v"),
            mi("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            mi("Close", #selector(NSWindow.performClose(_:)), "w"),
            mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.mainMenu = main
    }

    private func log(_ line: String) {
        Process.appendToLog(Config.logsDirectory + "/hummin-menubar.log", "[\(Int(Date().timeIntervalSince1970))] \(line)\n")
    }
}

// ---- entry -----------------------------------------------------------------

let (loadedServers, loadedHostOrder, loadedPath, configError): ([Server], [String], String?, String?) = {
    switch Config.load() {
    case .success(let (config, path)):
        Process.appendToLog(Config.logsDirectory + "/hummin-menubar.log",
            "[\(Int(Date().timeIntervalSince1970))] loaded \(config.servers.count) servers from \(path)\n")
        return (sortedServers(config), config.hostOrder, path, nil)
    case .failure(let error):
        return ([], [], nil, error.localizedDescription)
    }
}()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(store: FleetStore(servers: loadedServers, hostOrder: loadedHostOrder,
                                                 configPath: loadedPath, configError: configError, runner: ZshRunner()))
    app.delegate = delegate
    app.run() // delegate stays alive: run() never returns
}
