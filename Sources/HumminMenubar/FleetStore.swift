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
    // Warm state per warm-flagged server id: "warming-up" while the post-start
    // warmer (health poll + one-token "Hi") runs, "warm" once the "Hi" landed.
    // Anything else displays as "cold" - derived in the view, so rows started
    // before the menubar (or externally) show cold instead of a stale warm.
    private(set) var warmState: [String: String] = [:]
    var query = ""
    var expandedHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(expandedHosts).sorted(), forKey: "expandedHosts") }
    }

    @ObservationIgnored private let runner: CommandRunner
    @ObservationIgnored private var recheck = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var warmTried: Set<String> = []
    @ObservationIgnored private var warmTasks: [String: Task<Void, Never>] = [:]
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
                            // stderr is merged into the output (ssh warnings): the mode is the last line
                            let mode = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(whereSeparator: \.isNewline).last.map(String.init)?
                                .trimmingCharacters(in: .whitespaces) ?? ""
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
                    // a warm server that went down is cold again
                    for server in self.servers where server.warm == true && up[server.id] == false {
                        self.warmState[server.id] = nil
                        self.warmTried.remove(server.id)
                    }
                    // Adopt warm rows that are up but were not started here
                    // (external, or before the menubar): one cheap "Hi" tells
                    // their real warmth instead of "cold" forever. Once per up-period.
                    for server in self.servers where server.warm == true && up[server.id] == true
                        && self.warmState[server.id] == nil && self.warmTasks[server.id] == nil
                        && self.pending[server.id] == nil && !self.warmTried.contains(server.id) {
                        self.warmTried.insert(server.id)
                        self.beginWarmup(server)
                    }
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
                    if r.exit == 0, action == .start || action == .restart, server.warm == true {
                        self.beginWarmup(server)
                    }
                    if action == .stop { self.cancelWarmup(server) }
                    if action == .stop, server.warm == true { self.warmState[server.id] = nil }
                    self.refresh(force: true)
                }
            }
        }
    }

    // ---- warm-up -------------------------------------------------------------------

    // After a Start/Restart on a warm-flagged row: poll /health until the
    // server listens, then send a one-token "Hi". That first inference is what
    // pages lazy-mmap weights in, so the user's first real prompt skips the
    // multi-minute (or multi-hour, on a cold network mount) load.
    func beginWarmup(_ server: Server) {
        warmTasks[server.id]?.cancel()
        guard let hostIp = server.hostIp, let port = server.port else {
            Self.logAction("\(server.id) warm skipped: no hostIp/port in config")
            return
        }
        let base = "http://\(hostIp):\(port)"
        var bearer: String?
        if let keyFile = server.warmKeyFile {
            bearer = try? String(contentsOfFile: (keyFile as NSString).expandingTildeInPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        warmState[server.id] = "warming-up"
        let id = server.id
        let task = Task { [weak self] in
            defer { Task { @MainActor in
                self?.warmTasks[id] = nil
                self?.refresh(force: true)
            } }
            let ready = await Warmer.waitUntilHealthy(base: base, bearer: bearer,
                                                       deadline: Date().addingTimeInterval(1800))
            guard !Task.isCancelled else { return }
            if ready {
                // a server already working on a prompt has its weights paged in, and a "Hi"
                // would only queue behind that work (minutes to hours on a big CPU-MoE model)
                let busy = await Warmer.isBusy(base: base, bearer: bearer)
                let status = busy ? 200 : await Warmer.sayHi(base: base, bearer: bearer)
                await MainActor.run { self?.warmState[id] = status == 200 ? "warm" : nil }
                Self.logAction("\(id) warm exit=\(status)")
            } else {
                await MainActor.run { self?.warmState[id] = nil }
                Self.logAction("\(id) warm abandoned: /health never came up in 30 min")
            }
        }
        warmTasks[server.id] = task
    }

    func cancelWarmup(_ server: Server) {
        warmTasks[server.id]?.cancel()
        warmTasks[server.id] = nil
        warmState[server.id] = nil
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

// Minimal HTTP helpers for warm-up: URLSession only, no shell, cancellable via
// the Task. Health polls are cheap 4s requests; the "Hi" completion may run for
// minutes on a cold lazy-mmap server, so its resource timeout is generous.
enum Warmer {
    static func waitUntilHealthy(base: String, bearer: String?, deadline: Date) async -> Bool {
        while Date() < deadline {
            if Task.isCancelled { return false }
            let status = await status(for: request(base + "/health", bearer: bearer, method: "GET"), idleTimeout: 4)
            if status == 200 { return true }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return false
    }

    // llama-server GET /slots: any slot with is_processing means it is mid-request
    static func isBusy(base: String, bearer: String?) async -> Bool {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request(base + "/slots", bearer: bearer, method: "GET")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return slots.contains { ($0["is_processing"] as? Bool) == true }
    }

    static func sayHi(base: String, bearer: String?) async -> Int {
        let body: [String: Any] = ["messages": [["role": "user", "content": "Hi"]], "max_tokens": 1]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return -1 }
        var request = request(base + "/v1/chat/completions", bearer: bearer, method: "POST")
        request.httpBody = data
        return await status(for: request, idleTimeout: 3600, resourceTimeout: 3600)
    }

    private static func request(_ url: String, bearer: String?, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func status(for request: URLRequest, idleTimeout: TimeInterval, resourceTimeout: TimeInterval? = nil) async -> Int {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idleTimeout
        if let resourceTimeout { config.timeoutIntervalForResource = resourceTimeout }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }
}
