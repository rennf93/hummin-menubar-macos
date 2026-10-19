import Foundation

extension Process {
    static func run(_ cmd: String, _ args: [String], wait: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    // Hard deadline on every command: an unreachable host (or a stale mDNS
    // name) must never occupy a dispatch thread long enough to starve the
    // pool - that froze the whole menu once (64 hung ssh checks, Oct 2026).
    @discardableResult
    static func runCaptured(_ cmd: String, _ args: [String], timeout: TimeInterval = 8) -> (exit: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            guard waitWithDeadline(p, timeout) else { return (-1, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }

    @discardableResult
    static func waitWithDeadline(_ p: Process, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            p.terminate()
            for _ in 0..<20 where p.isRunning { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return false
        }
        return true
    }

    @discardableResult
    static func runLogged(_ cmd: String, _ args: [String], timeout: TimeInterval = 10) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            guard waitWithDeadline(p, timeout) else {
                appendToLog(Config.logsDirectory + "/hummin-menubar-health.log",
                    "[\(Int(Date().timeIntervalSince1970))] TIMEOUT after \(Int(timeout))s args=\(args.joined(separator: " "))\n")
                return -1
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let line = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let logLine = "[\(Int(Date().timeIntervalSince1970))] exit=\(p.terminationStatus) args=\(args.joined(separator: " ")) out=\(line.prefix(2000))\n"
            appendToLog(Config.logsDirectory + "/hummin-menubar-health.log", logLine)
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    static func appendToLog(_ path: String, _ text: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? text.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
