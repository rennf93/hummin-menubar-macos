import Foundation

extension Process {
    static func run(_ cmd: String, _ args: [String], wait: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    @discardableResult
    static func runCaptured(_ cmd: String, _ args: [String]) -> (exit: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }

    @discardableResult
    static func runLogged(_ cmd: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
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
