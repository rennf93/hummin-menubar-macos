import XCTest
import FleetCore

final class FleetCoreTests: XCTestCase {
    override func setUp() {
        let dir = NSTemporaryDirectory() + "hmb-test-logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("HUMMIN_MENUBAR_LOGS", dir, 1)
    }

    func srv(_ id: String, label: String? = nil, host: String = "Mac", port: UInt16? = nil, mutex: String? = nil) -> Server {
        Server(id: id, label: label ?? id, host: host, port: port, up: "U", down: "D", health: "H", mutexGroup: mutex)
    }

    // ---- rowState ----------------------------------------------------------------

    func testRowStateFullTable() {
        let ups: [Bool?] = [nil, true, false]
        let pendings: [ServerAction?] = [nil, .start, .stop, .restart]
        for up in ups {
            for pending in pendings {
                for checked in [true, false] {
                    let s = rowState(up: up, pending: pending, checked: checked)
                    let ctx = "up=\(String(describing: up)) pending=\(String(describing: pending)) checked=\(checked)"
                    switch pending {
                    case .start?:
                        XCTAssertEqual(s.phase, .pending(.start), ctx); XCTAssertEqual(s.stateWord, "Starting...", ctx)
                        XCTAssertEqual([s.canStart, s.canStop, s.canRestart], [false, true, false], ctx)
                    case .restart?:
                        XCTAssertEqual(s.phase, .pending(.restart), ctx); XCTAssertEqual(s.stateWord, "Restarting...", ctx)
                        XCTAssertEqual([s.canStart, s.canStop, s.canRestart], [false, true, false], ctx)
                    case .stop?:
                        XCTAssertEqual(s.phase, .pending(.stop), ctx); XCTAssertEqual(s.stateWord, "Stopping...", ctx)
                        XCTAssertEqual([s.canStart, s.canStop, s.canRestart], [false, false, false], ctx)
                    case nil:
                        let expectPhase: ServerPhase = up == true ? .running : up == false ? .stopped : (checked ? .noResponse : .checking)
                        let word = up == true ? "Running" : up == false ? "Stopped" : (checked ? "No response" : "Checking...")
                        XCTAssertEqual(s.phase, expectPhase, ctx); XCTAssertEqual(s.stateWord, word, ctx)
                        XCTAssertEqual([s.canStart, s.canStop, s.canRestart],
                                       up == true ? [false, true, true] : [true, false, false], ctx)
                    }
                }
            }
        }
    }

    // ---- summaries, filter, siblings, commands, ordering ------------------------------

    func testFleetSummary() {
        XCTAssertEqual(fleetSummary(total: 45, running: 3, checked: false), "Checking...")
        XCTAssertEqual(fleetSummary(total: 45, running: 0, checked: true), "All servers stopped")
        XCTAssertEqual(fleetSummary(total: 45, running: 3, checked: true), "3 of 45 running")
    }

    func testRunningCount() {
        let all = [srv("a"), srv("b"), srv("c")]
        XCTAssertEqual(runningCount(all, up: ["a": true, "b": false]), 1)
    }

    func testMatches() {
        let s = srv("mac-qwen", label: "Qwen 3.8 27B", host: "NAS", port: 9998)
        for q in ["qwen", "QWEN", "mac-q", "nas", "9998", "999", "27b", ""] { XCTAssertTrue(matches(s, query: q), q) }
        XCTAssertFalse(matches(s, query: "ornith"))
        XCTAssertFalse(matches(srv("x"), query: "9"))
    }

    func testMutexSiblings() {
        let a = srv("a", mutex: "g"), b = srv("b", mutex: "g"), c = srv("c", mutex: "h"), d = srv("d")
        XCTAssertEqual(mutexSiblings(of: a, in: [a, b, c, d]).map(\.id), ["b"])
        XCTAssertEqual(mutexSiblings(of: d, in: [a, b, c, d]), [])
        XCTAssertEqual(mutexSiblings(of: c, in: [a, b, c, d]), [])
    }

    func testCommand() {
        let s = srv("a")
        XCTAssertEqual(command(for: .start, on: s), "U")
        XCTAssertEqual(command(for: .stop, on: s), "D")
        XCTAssertEqual(command(for: .restart, on: s), "D; sleep 2; U")
    }

    func testSortedServers() {
        let cfg = MenubarConfig(hostOrder: ["Mac", "Laptop"], servers: [
            srv("1", label: "zeta", host: "Laptop"), srv("2", label: "beta", host: "Mac"),
            srv("3", label: "Alpha", host: "Other"), srv("4", label: "alpha", host: "Mac"),
            srv("5", label: "Omega", host: "Laptop"),
        ])
        XCTAssertEqual(sortedServers(cfg).map(\.id), ["4", "2", "5", "1", "3"])
    }

    // ---- Process ------------------------------------------------------------------------

    func testPipeDrainDoesNotTimeOut() {
        let r = Process.runLoggedCaptured("/bin/zsh", ["-lc", "head -c 200000 /dev/zero; exit 0"], timeout: 10)
        XCTAssertEqual(r.exit, 0)
        XCTAssertEqual(Process.runLogged("/bin/zsh", ["-lc", "head -c 200000 /dev/zero; exit 3"], timeout: 10), 3)
        XCTAssertEqual(Process.runCaptured("/bin/zsh", ["-lc", "echo hi"]).out, "hi\n")
    }

    func testDeadlineKills() {
        let start = Date()
        XCTAssertEqual(Process.runLogged("/bin/zsh", ["-lc", "sleep 30"], timeout: 1), -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let start2 = Date()
        Process.run("/bin/zsh", ["-lc", "sleep 30"], wait: true, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start2), 3)
    }
}
