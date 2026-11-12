import Foundation
import Observation
#if canImport(FleetCore)
import FleetCore
#endif

protocol CommandRunner: Sendable {
    func run(_ command: String, timeout: TimeInterval) -> (exit: Int32, out: String)
}

/// Runs through the login shell and writes the health log like the dropdown always did.
struct ZshRunner: CommandRunner {
    func run(_ command: String, timeout: TimeInterval) -> (exit: Int32, out: String) {
        Process.runLoggedCaptured("/bin/zsh", ["-lc", command], timeout: timeout)
    }
}

@MainActor @Observable
final class FleetStore {
    let servers: [Server]
    let hostOrder: [String]
    let configPath: String?
    let configError: String?
    private(set) var up: [String: Bool] = [:]
    private(set) var modes: [String: String] = [:]
    private(set) var pending: [String: ServerAction] = [:]
    private(set) var pendingMode: [String: String] = [:]
    private(set) var lastResult: [String: ActionResult] = [:]
    private(set) var lastCheck: Date?
    private(set) var checking = false
    var query = ""
    var expandedHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(expandedHosts).sorted(), forKey: "expandedHosts") }
    }

    @ObservationIgnored private let runner: CommandRunner
    @ObservationIgnored private var recheck = false
    @ObservationIgnored private var timer: Timer?
    private static let checkTTL: TimeInterval = 5

    init(servers: [Server], hostOrder: [String], configPath: String?, configError: String?, runner: CommandRunner) {
        self.servers = servers
        self.hostOrder = hostOrder
        self.configPath = configPath
        self.configError = configError
        self.runner = runner
        self.expandedHosts = Set(UserDefaults.standard.stringArray(forKey: "expandedHosts") ?? [])
    }

    // ---- checking ---------------------------------------------------------------

    func refresh(force: Bool) {
        if checking {
            if force { recheck = true } // one more check when this one lands
            return
        }
        if !force, let t = lastCheck, Date().timeIntervalSince(t) < Self.checkTTL { return }
        checking = true
        let servers = self.servers, runner = self.runner
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "health", attributes: .concurrent)
            let lock = NSLock()
            var results = [String: Bool]()
            var modeResults = [String: String]()
            for server in servers {
                group.enter()
                queue.async {
                    let r = runner.run(server.health, timeout: 5)
                    // -1 = missed the deadline: no entry, the row reads "No response".
                    if r.exit != -1 { lock.lock(); results[server.id] = (r.exit == 0); lock.unlock() }
                    group.leave()
                }
                if let modeGet = server.modeGet {
                    group.enter()
                    queue.async {
                        let r = runner.run(modeGet, timeout: 5)
                        if r.exit == 0 {
                            let mode = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                            lock.lock(); modeResults[server.id] = mode; lock.unlock()
                        }
                        group.leave()
                    }
                }
            }
            _ = group.wait(timeout: .now() + 6)
            lock.lock(); let up = results, modes = modeResults; lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.up = up
                    self.modes = modes
                    self.lastCheck = Date()
                    self.checking = false
                    if self.recheck { self.recheck = false; self.refresh(force: true) }
                }
            }
        }
    }

    func startPolling() {
        // show + the occlusion change both call this; a second call must not force another round
        guard timer == nil else { return }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.checking { self.refresh(force: true) } }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // ---- actions ------------------------------------------------------------------

    func perform(_ action: ServerAction, on server: Server) {
        guard pending[server.id] == nil else { return }
        pending[server.id] = action
        let siblings = action == .stop ? [] : mutexSiblings(of: server, in: servers)
        let cmd = command(for: action, on: server)
        let runner = self.runner
        DispatchQueue.global().async {
            // Resource-sharers are exclusive: stop the others in the group first.
            for other in siblings { _ = runner.run(other.down, timeout: 25) }
            if !siblings.isEmpty { Thread.sleep(forTimeInterval: 2) }
            let r = runner.run(cmd, timeout: 25)
            Self.logAction("\(server.id) \(action.rawValue) exit=\(r.exit) cmd=\(cmd)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.lastResult[server.id] = ActionResult(action: action, exitCode: r.exit, finishedAt: Date())
                    self.pending[server.id] = nil
                    self.refresh(force: true)
                }
            }
        }
    }

    func setMode(_ mode: String, on server: Server) {
        guard let template = server.modeSet, pendingMode[server.id] == nil else { return }
        let cmd = template.replacingOccurrences(of: "{mode}", with: mode)
        pendingMode[server.id] = mode
        Self.logAction("\(server.id) mode=\(mode) cmd=\(cmd)")
        let runner = self.runner
        DispatchQueue.global().async {
            let r = runner.run(cmd, timeout: 10)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if r.exit == 0 { self.modes[server.id] = mode } // until the forced refresh lands
                    self.pendingMode[server.id] = nil
                    self.refresh(force: true)
                }
            }
        }
    }

    nonisolated static func logAction(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        Process.appendToLog(Config.logsDirectory + "/hummin-menubar-actions.log", "[\(f.string(from: Date()))] \(line)\n")
    }
}
