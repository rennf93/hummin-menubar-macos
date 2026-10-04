import AppKit

final class MenuDelegateRef: NSObject, NSMenuDelegate {
    let onUpdate: () -> Void
    init(onUpdate: @escaping () -> Void) { self.onUpdate = onUpdate }
    func menuWillOpen(_ _: NSMenu) { onUpdate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let servers: [Server]       // sorted: hostOrder first, label alphabetically within a host
    let hostOrder: [String]
    let configError: String?

    var statusLine: NSMenuItem?
    var menuDelegate: MenuDelegateRef?
    var hostItems: [String: NSMenuItem] = [:]
    var serverRows: [String: NSMenuItem] = [:]
    var serverButtons: [String: (start: NSMenuItem, stop: NSMenuItem, restart: NSMenuItem)] = [:]
    var modeMenus: [String: (parent: NSMenuItem, items: [String: NSMenuItem])] = [:]
    var pending: [String: String] = [:]
    let pendingLock = NSLock()

    // Health cache: the menu renders instantly from this, checks run in the
    // background, and results land on the next render. Checks are skipped
    // within the TTL so menuWillOpen + action callbacks never stack up.
    private var cachedUp: [String: Bool] = [:]
    private var cachedModes: [String: String] = [:]
    private var lastCheck: Date?
    private var checking = false
    private let checkTTL: TimeInterval = 5

    init(servers: [Server], hostOrder: [String], configError: String?) {
        self.servers = servers
        self.hostOrder = hostOrder
        self.configError = configError
        super.init()
    }

    func applicationDidFinishLaunching(_ _: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.button?.image = templateBirdImage()

        let status = NSMenuItem(title: "Status: checking...", action: nil, keyEquivalent: "")
        menu.addItem(status)
        statusLine = status

        if let error = configError {
            // Still fully usable as a menu (Quit works); the error row explains
            // what is missing without popping a dialog at login.
            let err = NSMenuItem(title: "Config error (see log)", action: nil, keyEquivalent: "")
            err.isEnabled = false
            menu.addItem(err)
            statusLine?.title = "Config error (see log)"
            log(error)
        }

        // One top-level item per host; hovering it reveals the host's model
        // rows, and each row keeps its usual Start/Stop/Restart submenu.
        for host in hostOrder {
            let hostItem = NSMenuItem(title: host, action: nil, keyEquivalent: "")
            let hostMenu = NSMenu()
            hostMenu.autoenablesItems = false
            for server in servers where server.host == host {
                let row = NSMenuItem(title: "\(server.label)\(portSuffix(server))", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                let start = NSMenuItem(title: "Start", action: #selector(upObj(_:)), keyEquivalent: "")
                let stop = NSMenuItem(title: "Stop", action: #selector(downObj(_:)), keyEquivalent: "")
                let restart = NSMenuItem(title: "Restart", action: #selector(restartObj(_:)), keyEquivalent: "")
                for item in [start, stop, restart] {
                    item.target = self
                    item.representedObject = server
                    sub.addItem(item)
                }
                if let modes = server.modes {
                    let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
                    let modeMenu = NSMenu()
                    modeMenu.autoenablesItems = false
                    var items = [String: NSMenuItem]()
                    for m in modes {
                        let mi = NSMenuItem(title: m, action: #selector(modeObj(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = ["server": server, "mode": m]
                        modeMenu.addItem(mi)
                        items[m] = mi
                    }
                    modeItem.submenu = modeMenu
                    sub.addItem(modeItem)
                    modeMenus[server.id] = (modeItem, items)
                }
                row.submenu = sub
                hostMenu.addItem(row)
                serverRows[server.id] = row
                serverButtons[server.id] = (start, stop, restart)
            }
            hostItem.submenu = hostMenu
            menu.addItem(hostItem)
            hostItems[host] = hostItem
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit menubar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menuDelegate = MenuDelegateRef { [weak self] in
            self?.render()
            self?.scheduleCheck(force: false)
        }
        menu.delegate = menuDelegate
        statusItem.menu = menu
        render()
        scheduleCheck(force: true)
    }

    func portSuffix(_ server: Server) -> String {
        server.port.map { " :\($0)" } ?? ""
    }

    // ---- rendering (main thread, instant, cache-driven) -----------------------

    func render() {
        var upCount = 0
        var hostUp = [String: Int]()
        pendingLock.lock()
        let pendingNow = pending
        pendingLock.unlock()

        for server in servers {
            let up = cachedUp[server.id] ?? false
            if up {
                upCount += 1
                hostUp[server.host, default: 0] += 1
            }
            let state = pendingNow[server.id]
            let mark = state != nil ? "  ◐" : (up ? "  ●" : "  ○")
            let suffix = state.map { "  \($0)ing..." } ?? ""
            let mode = cachedModes[server.id]
            let modeText = mode.map { " ·\($0)" } ?? ""
            serverRows[server.id]?.title = "\(server.label)\(portSuffix(server))\(modeText)\(mark)\(suffix)"

            // Button states reflect the transition: while starting or
            // restarting, Start/Restart are disabled and Stop stays live
            // (an abort lever); while stopping everything is disabled.
            if let b = serverButtons[server.id] {
                switch state {
                case "start":
                    b.start.isEnabled = false; b.stop.isEnabled = true; b.restart.isEnabled = false
                case "stop":
                    b.start.isEnabled = false; b.stop.isEnabled = false; b.restart.isEnabled = false
                case "restart":
                    b.start.isEnabled = false; b.stop.isEnabled = true; b.restart.isEnabled = false
                default:
                    b.start.isEnabled = !up
                    b.stop.isEnabled = up
                    b.restart.isEnabled = up
                }
            }
            if let mm = modeMenus[server.id] {
                for (m, mi) in mm.items { mi.state = m == mode ? .on : .off }
            }
        }
        for host in hostOrder {
            let n = hostUp[host] ?? 0
            hostItems[host]?.title = n > 0 ? "\(host)  (\(n) running)" : host
        }
        if statusLine?.title == "Status: checking..." || cachedUp.isEmpty {
            // keep the initial line until the first real check has landed
        } else {
            statusLine?.title = upCount == 0 ? "All servers stopped" : "\(upCount) server(s) running"
        }
    }

    // ---- checking (background, TTL-guarded) -----------------------------------

    func scheduleCheck(force: Bool) {
        guard !checking else { return }
        if !force, let t = lastCheck, Date().timeIntervalSince(t) < checkTTL { return }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "health", attributes: .concurrent)
            var results = [String: Bool]()
            var modeResults = [String: String]()
            let lock = NSLock()
            for server in self.servers {
                group.enter()
                queue.async {
                    let exit = Process.runLogged("/bin/zsh", ["-lc", server.health])
                    lock.lock(); results[server.id] = (exit == 0); lock.unlock()
                    group.leave()
                }
                if let modeGet = server.modeGet {
                    group.enter()
                    queue.async {
                        let r = Process.runCaptured("/bin/zsh", ["-lc", modeGet])
                        let mode = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                        lock.lock()
                        if r.exit == 0 { modeResults[server.id] = mode }
                        lock.unlock()
                        group.leave()
                    }
                }
            }
            _ = group.wait(timeout: .now() + 5)
            DispatchQueue.main.async {
                self.cachedUp = results
                self.cachedModes = modeResults
                self.lastCheck = Date()
                self.checking = false
                self.render()
            }
        }
    }

    // ---- actions ---------------------------------------------------------------

    func act(_ server: Server, _ action: String) {
        pendingLock.lock()
        if pending[server.id] != nil { pendingLock.unlock(); return }
        pending[server.id] = action
        pendingLock.unlock()
        render()

        DispatchQueue.global().async {
            defer {
                self.pendingLock.lock()
                self.pending[server.id] = nil
                self.pendingLock.unlock()
                DispatchQueue.main.async { self.scheduleCheck(force: true) }
            }
            if action == "start" || action == "restart" {
                // Resource-sharers are exclusive: stop the others in the group first.
                if let group = server.mutexGroup {
                    for other in self.servers where other.id != server.id && other.mutexGroup == group {
                        Process.run("/bin/zsh", ["-lc", other.down], wait: true)
                    }
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            let command: String
            switch action {
            case "stop": command = server.down
            case "start": command = server.up
            default: command = "\(server.down); sleep 2; \(server.up)"
            }
            let exited = Process.runLogged("/bin/zsh", ["-lc", command])
            self.logAction("\(server.id) \(action) exit=\(exited) cmd=\(command)")
        }
    }

    private func log(_ line: String) {
        Process.appendToLog(Config.logsDirectory + "/hummin-menubar.log", "[\(Int(Date().timeIntervalSince1970))] \(line)\n")
    }

    private func logAction(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        Process.appendToLog(Config.logsDirectory + "/hummin-menubar-actions.log", "[\(f.string(from: Date()))] \(line)\n")
    }

    @objc func upObj(_ sender: NSMenuItem) { act(sender.representedObject as! Server, "start") }
    @objc func downObj(_ sender: NSMenuItem) { act(sender.representedObject as! Server, "stop") }
    @objc func restartObj(_ sender: NSMenuItem) { act(sender.representedObject as! Server, "restart") }
    @objc func modeObj(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
            let server = info["server"] as? Server,
            let mode = info["mode"] as? String,
            let template = server.modeSet else { return }
        let command = template.replacingOccurrences(of: "{mode}", with: mode)
        logAction("\(server.id) mode=\(mode) cmd=\(command)")
        DispatchQueue.global().async {
            Process.runLogged("/bin/zsh", ["-lc", command])
            DispatchQueue.main.async { self.scheduleCheck(force: true) }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// ---- entry -----------------------------------------------------------------

let (loadedServers, loadedHostOrder, configError): ([Server], [String], String?) = {
    switch Config.load() {
    case .success(let (config, path)):
        let order = config.hostOrder
        let sorted = config.servers.sorted { a, b in
            let ah = order.firstIndex(of: a.host) ?? order.count
            let bh = order.firstIndex(of: b.host) ?? order.count
            if ah != bh { return ah < bh }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        Process.appendToLog(Config.logsDirectory + "/hummin-menubar.log",
            "[\(Int(Date().timeIntervalSince1970))] loaded \(config.servers.count) servers from \(path)\n")
        return (sorted, order, nil)
    case .failure(let error):
        return ([], [], error.localizedDescription)
    }
}()

let app = NSApplication.shared
let delegate = AppDelegate(servers: loadedServers, hostOrder: loadedHostOrder, configError: configError)
app.delegate = delegate
app.run()
