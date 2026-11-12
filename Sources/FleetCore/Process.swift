import Foundation

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "<non-utf8>" }
}

extension Process {
    // Hard deadline on every command: an unreachable host (or a stale mDNS
    // name) must never occupy a dispatch thread long enough to starve the
    // pool - that froze the whole menu once (64 hung ssh checks, Oct 2026).
    // Output is drained while the process runs: a child writing more than the
    // 64 KB pipe buffer would otherwise block until the deadline killed it.
    // Returns nil on launch failure or timeout.
    private static func execute(_ cmd: String, _ args: [String], timeout: TimeInterval) -> (exit: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let box = OutputBox()
        let eof = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; eof.signal() } else { box.append(d) }
        }
        defer { reader.readabilityHandler = nil; try? reader.close() }
        do { try p.run() } catch { return nil }
        guard waitWithDeadline(p, timeout) else { return nil }
        // Grandchildren may keep the pipe open; do not wait for them for long.
        _ = eof.wait(timeout: .now() + 1)
        return (p.terminationStatus, box.text)
    }

    @discardableResult
    public static func runCaptured(_ cmd: String, _ args: [String], timeout: TimeInterval = 8) -> (exit: Int32, out: String) {
        execute(cmd, args, timeout: timeout) ?? (-1, "")
    }

    @discardableResult
    public static func waitWithDeadline(_ p: Process, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            for _ in 0..<20 where p.isRunning { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return false
        }
        return true
    }

    // Like runCaptured, and writes the health log line exactly as runLogged always has.
    @discardableResult
    public static func runLoggedCaptured(_ cmd: String, _ args: [String], timeout: TimeInterval = 10) -> (exit: Int32, out: String) {
        let log = Config.logsDirectory + "/hummin-menubar-health.log"
        guard let r = execute(cmd, args, timeout: timeout) else {
            appendToLog(log, "[\(Int(Date().timeIntervalSince1970))] TIMEOUT after \(Int(timeout))s args=\(args.joined(separator: " "))\n")
            return (-1, "")
        }
        appendToLog(log, "[\(Int(Date().timeIntervalSince1970))] exit=\(r.exit) args=\(args.joined(separator: " ")) out=\(r.out.prefix(2000))\n")
        return r
    }

    @discardableResult
    public static func runLogged(_ cmd: String, _ args: [String], timeout: TimeInterval = 10) -> Int32 {
        runLoggedCaptured(cmd, args, timeout: timeout).exit
    }

    // wait: true is runLogged with a deadline (a hung ssh must not block forever).
    public static func run(_ cmd: String, _ args: [String], wait: Bool, timeout: TimeInterval = 25) {
        if wait {
            runLogged(cmd, args, timeout: timeout)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd)
            p.arguments = args
            try? p.run()
        }
    }

    public static func appendToLog(_ path: String, _ text: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? text.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
