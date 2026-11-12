import Foundation

public enum ServerAction: String, Sendable, CaseIterable { case start, stop, restart }

public enum ServerPhase: Equatable, Sendable {
    case checking                // no check has completed yet
    case noResponse              // a check completed but this server's health command missed the deadline
    case running
    case stopped
    case pending(ServerAction)
}

public struct RowState: Equatable, Sendable {
    public var phase: ServerPhase
    public var stateWord: String
    public var canStart: Bool
    public var canStop: Bool
    public var canRestart: Bool
}

/// The dropdown's button rules: pending start or restart -> only Stop (abort lever);
/// pending stop -> nothing; idle -> Start when not up, Stop and Restart when up.
public func rowState(up: Bool?, pending: ServerAction?, checked: Bool) -> RowState {
    if let pending {
        let word: String
        switch pending {
        case .start: word = "Starting..."
        case .stop: word = "Stopping..."
        case .restart: word = "Restarting..."
        }
        return RowState(phase: .pending(pending), stateWord: word, canStart: false,
                        canStop: pending != .stop, canRestart: false)
    }
    let isUp = up == true
    let phase: ServerPhase, word: String
    switch up {
    case true?: phase = .running; word = "Running"
    case false?: phase = .stopped; word = "Stopped"
    case nil where checked: phase = .noResponse; word = "No response"
    case nil: phase = .checking; word = "Checking..."
    }
    return RowState(phase: phase, stateWord: word, canStart: !isUp, canStop: isUp, canRestart: isUp)
}

public struct ActionResult: Equatable, Sendable {
    public var action: ServerAction
    public var exitCode: Int32   // -1 = timed out or failed to launch
    public var finishedAt: Date
    public var succeeded: Bool { exitCode == 0 }
    public init(action: ServerAction, exitCode: Int32, finishedAt: Date) {
        self.action = action; self.exitCode = exitCode; self.finishedAt = finishedAt
    }
}

public func sortedServers(_ config: MenubarConfig) -> [Server] {
    let order = config.hostOrder
    return config.servers.sorted { a, b in
        let ah = order.firstIndex(of: a.host) ?? order.count
        let bh = order.firstIndex(of: b.host) ?? order.count
        if ah != bh { return ah < bh }
        return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }
}

public func mutexSiblings(of server: Server, in servers: [Server]) -> [Server] {
    guard let group = server.mutexGroup else { return [] }
    return servers.filter { $0.id != server.id && $0.mutexGroup == group }
}

public func runningCount(_ servers: [Server], up: [String: Bool]) -> Int {
    servers.filter { up[$0.id] == true }.count
}

public func fleetSummary(total: Int, running: Int, checked: Bool) -> String {
    if !checked { return "Checking..." }
    return running == 0 ? "All servers stopped" : "\(running) of \(total) running"
}

public func matches(_ server: Server, query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return true }
    let fields = [server.label, server.id, server.host, server.port.map { String($0) } ?? ""]
    return fields.contains { $0.localizedCaseInsensitiveContains(q) }
}

public func command(for action: ServerAction, on server: Server) -> String {
    switch action {
    case .stop: return server.down
    case .start: return server.up
    case .restart: return "\(server.down); sleep 2; \(server.up)"
    }
}
