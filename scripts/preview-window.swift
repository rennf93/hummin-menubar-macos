// Preview harness for the fleet window: renders FleetView in an NSHostingView
// inside an offscreen-ish NSWindow and captures it with cacheDisplay (ImageRenderer
// draws Picker/ProgressView/bordered buttons as placeholders, so it is not used).
// Needs the GUI session: over ssh, run it as a one-shot LaunchAgent in gui/$(id -u).
//
// Usage (top-level code must live in a file named main.swift):
//   tmp=$(mktemp -d)
//   cp Sources/FleetCore/{Config,Process,FleetModel}.swift $tmp/
//   cp Sources/HumminMenubar/{FleetStore,FleetWindow}.swift $tmp/
//   cp scripts/preview-window.swift $tmp/main.swift
//   swiftc -O $tmp/*.swift -o $tmp/preview
//   $tmp/preview outdir      # writes window-light.png, window-dark.png, window-search.png
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let logDir = NSTemporaryDirectory() + "hummin-preview-logs"
try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
setenv("HUMMIN_MENUBAR_LOGS", logDir, 1) // never touch the real logs

// Invented fleet. Commands are tokens the canned runner understands.
func s(_ id: String, _ label: String, _ host: String, _ port: UInt16?, mutex: String? = nil, modes: [String]? = nil) -> Server {
    Server(id: id, label: label, host: host, port: port, up: "up \(id)", down: "down \(id)", health: "health \(id)",
           mutexGroup: mutex, modes: modes, modeGet: modes == nil ? nil : "modeget", modeSet: modes == nil ? nil : "modeset {mode}")
}
let fleet = [
    s("mac-qwen", "Qwen 3.8 27B", "Mac", 9998),
    s("mac-replay-trimmer", "Replay Trimmer", "Mac", 4100, modes: ["all", "strip", "off"]),
    s("laptop-ornith", "Ornith 1.5 35B", "Laptop", 9981, mutex: "laptop-gpu"),
    s("nas-north", "North Mini Code", "NAS", 9992),
    s("pi-router", "Router", "Pi", 9990),
]
let running: Set<String> = ["mac-replay-trimmer"]

struct Canned: CommandRunner {
    func run(_ command: String, timeout: TimeInterval) -> (exit: Int32, out: String) {
        if command.hasPrefix("health ") {
            let id = String(command.dropFirst(7))
            if id == "pi-router" { return (-1, "") }          // no response
            return (running.contains(id) ? 0 : 1, "")
        }
        if command == "modeget" { return (0, "strip\n") }
        if command == "up laptop-ornith" { Thread.sleep(forTimeInterval: 120); return (0, "") } // stays pending
        if command == "up nas-north" { return (1, "") }     // failed
        return (0, "")
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let store = FleetStore(servers: fleet, hostOrder: ["Mac", "Laptop", "NAS", "Pi"],
                           configPath: "/Users/demo/.config/hummin-menubar/servers.json", configError: nil, runner: Canned())
    store.expandedHosts = ["Mac", "Laptop", "NAS"]
    store.perform(.start, on: fleet[2])
    store.perform(.start, on: fleet[3])
    store.refresh(force: true)
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))

    @MainActor func capture(dark: Bool, query: String, file: String) {
        store.query = query
        let host = NSHostingView(rootView: FleetView(store: store).background(Color(nsColor: .windowBackgroundColor)))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir + "/" + file))
        win.orderOut(nil)
    }
    capture(dark: false, query: "", file: "window-light.png")
    capture(dark: true, query: "", file: "window-dark.png")
    capture(dark: false, query: "99", file: "window-search.png")
}
exit(0)
