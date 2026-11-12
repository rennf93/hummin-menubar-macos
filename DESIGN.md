# hummin-menubar window design contract

The menubar app is a status item that opens one native window: the fleet. The dropdown menu it replaces became unusable at 45 servers across 4 hosts. The window's structure follows the hummin page in the NixOS settings shell: host cards that expand and collapse, and server rows with state, port, mode and inline actions. It uses native macOS materials and controls.

## Rules

1. **UX first.** One glance answers "what is running, where, and did my last action work?" Failures are shown in the row, not only in a log file.
2. **Native.** SwiftUI inside an `NSWindow`, SF Symbols, system accent, system materials, automatic light and dark. No custom colors except the status tones (green running, orange pending, red failed). The tones always come with a word.
3. **Behavior parity.** Action semantics, mutex groups, mode switching, health checks, timeouts and log formats are unchanged from the dropdown, and `servers.json` stays byte-compatible with the Linux app.
4. **Energy.** Health checks run only while the window is visible, plus once at launch. Nothing polls in the background.

## Targets

`Package.swift` uses swift-tools 5.9 and platform macOS 14 (`@Observable`, `phaseAnimator`). There are three targets:

- `FleetCore` (library, `Sources/FleetCore`): `Config.swift`, `Process.swift` and `FleetModel.swift`. Foundation only, no AppKit or SwiftUI.
- `HumminMenubar` (executable, `Sources/HumminMenubar`): `main.swift`, `Bird.swift`, `FleetStore.swift`, `FleetWindow.swift` and `Resources/`. Depends on `FleetCore`.
- `FleetCoreTests` (test, `Tests/FleetCoreTests`).

## FleetCore API (pure, unit-tested)

```swift
public struct Server: Codable, Hashable, Sendable   // unchanged fields, now public
public struct MenubarConfig: Codable, Sendable      // unchanged
public enum Config                                  // unchanged API, now public

public enum ServerAction: String, Sendable, CaseIterable { case start, stop, restart }

public enum ServerPhase: Equatable, Sendable {
    case checking                // no check has completed yet (lastCheck == nil)
    case noResponse              // a check completed but this server's health command missed the deadline
    case running
    case stopped
    case pending(ServerAction)
}

public struct RowState: Equatable, Sendable {
    public var phase: ServerPhase
    public var stateWord: String // "Checking...", "No response", "Running", "Stopped", "Starting...", "Stopping...", "Restarting..."
    public var canStart: Bool
    public var canStop: Bool
    public var canRestart: Bool
}

/// The dropdown's render() button rules, moved unchanged:
/// pending start or restart -> only Stop enabled (abort lever); pending stop -> nothing enabled;
/// idle -> Start when not up, Stop and Restart when up. up == nil counts as not up for the buttons.
/// The words are new: the dropdown printed "stoping..." (a "\(action)ing" typo), the window says "Stopping...".
public func rowState(up: Bool?, pending: ServerAction?, checked: Bool) -> RowState

public struct ActionResult: Equatable, Sendable {
    public var action: ServerAction
    public var exitCode: Int32   // -1 = timed out or failed to launch
    public var finishedAt: Date
    public var succeeded: Bool { exitCode == 0 }
}

public func sortedServers(_ config: MenubarConfig) -> [Server]          // hostOrder first, then label, as main.swift does today
public func mutexSiblings(of server: Server, in servers: [Server]) -> [Server]
public func runningCount(_ servers: [Server], up: [String: Bool]) -> Int
public func fleetSummary(total: Int, running: Int, checked: Bool) -> String  // "Checking...", "All servers stopped", "3 of 45 running"
public func matches(_ server: Server, query: String) -> Bool             // case-insensitive over label, id, host and port; empty query matches
public func command(for action: ServerAction, on server: Server) -> String // stop: down; start: up; restart: "<down>; sleep 2; <up>"
```

`Process.swift` fixes, each covered by a test:

- `Process.run(_:_:wait:)` gets the same deadline as `runLogged`, because a hung `ssh` mutex stop could block a thread forever. It becomes `runLogged` with a timeout.
- `runCaptured` and `runLogged` drain the pipe while the process runs, using `readabilityHandler` or a reader thread. Today a command writing more than the 64 KB pipe buffer blocks until the deadline kills it, so it reports `-1` instead of its real exit. Test: `head -c 200000 /dev/zero; exit 0` returns exit `0`.

## FleetStore (executable target, `@MainActor @Observable`)

```swift
protocol CommandRunner: Sendable {
    func run(_ command: String, timeout: TimeInterval) -> (exit: Int32, out: String)
}
struct ZshRunner: CommandRunner        // /bin/zsh -lc, logs exactly like today's runLogged

@MainActor @Observable final class FleetStore {
    let servers: [Server]
    let hostOrder: [String]
    let configPath: String?
    let configError: String?
    private(set) var up: [String: Bool]
    private(set) var modes: [String: String]
    private(set) var pending: [String: ServerAction]
    private(set) var lastResult: [String: ActionResult]
    private(set) var lastCheck: Date?
    private(set) var checking: Bool
    var query: String
    var expandedHosts: Set<String>      // persisted in UserDefaults key "expandedHosts"; first launch expands none

    private(set) var pendingMode: [String: String] // server id -> mode being applied
    init(servers: [Server], hostOrder: [String], configPath: String?, configError: String?, runner: CommandRunner)
    func refresh(force: Bool)           // 5 s TTL unless forced; concurrent checks, 5 s group deadline
    func perform(_ action: ServerAction, on server: Server)
    func setMode(_ mode: String, on server: Server) // 10 s timeout (unchanged); pendingMode set while it runs, then refresh(force: true)
    func startPolling()                 // refresh(force: true), then every 5 s
    func stopPolling()
}
```

Semantics. The dropdown behavior is kept, and the defects the contract review found are fixed:

- `perform`: mutex siblings are stopped first through the runner with a 25 s deadline (the dropdown used `Process.run`, which had no deadline). The 2 s settle runs only when at least one sibling exists (the dropdown slept whenever `mutexGroup` was set). Then the action command runs with the 25 s timeout and `lastResult` is recorded. `hummin-menubar-actions.log` gets the same line format, written by the store (`logAction`). The health log is still written by `runLogged`.
- `refresh(force: true)` while a check is running is no longer dropped: it sets a flag and exactly one more check runs when the current one lands. The dropdown silently skipped the post-action refresh in that case.
- Check results are collected under the lock and copied under the lock before being published on the main actor. The dropdown read the dictionary on main without the lock.
- Result words: an exit of `-1` reads "<Action> timed out". Any other non-zero exit reads "<Action> failed (exit N)".

## Status item

- Left click toggles the window: open, or bring it to front if it is behind other windows, or close it if it is already the key window.
- Right click opens a menu: "Open Hummin", "Refresh All" (Cmd-R), separator, "Quit Hummin Menubar" (Cmd-Q).
- The icon is the existing `BirdIcon.statusBarIcon()`.
- Activation policy is `.accessory` (no Dock icon). Opening the window calls `NSApp.activate()` so the window comes to front.
- A minimal main menu is installed so standard key equivalents work in an accessory app: App (Quit Cmd-Q), Edit (Undo, Redo, Cut, Copy, Paste, Select All), Window (Close Cmd-W, Minimize Cmd-M).

## Window

- `NSWindow` hosting `NSHostingController(rootView: FleetView(store:))`, titled "Hummin" with a unified toolbar style. Set `hostingController.sizingOptions = []` so SwiftUI does not fight the window's size or frame autosave.
- Default size 560x700, `contentMinSize` 460x420, `setFrameAutosaveName("HumminFleetWindow")`, `isReleasedWhenClosed = false`.
- Cmd-R and Cmd-F are `.keyboardShortcut`s on the view's Refresh button and on a hidden focus-search button. The status-item menu's key equivalents only work while that menu is open.
- Esc clears the search when it is non-empty, otherwise it closes the window.
- Polling starts when the window becomes visible (`windowDidChangeOcclusionState`, `orderFront`) and stops when it closes or is fully occluded.

### Layout (top to bottom)

1. **Header row:** the fleet summary ("12 of 45 running", `.contentTransition(.numericText())`), "Checked 3 s ago" (`TimelineView(.periodic(from:by: 1))`), a small `ProgressView` while checking, and a Refresh button (`arrow.clockwise`, Cmd-R).
2. **Search field:** magnifying glass prefix, placeholder "Filter servers", Cmd-F focuses it. With a query, hosts with matches auto-expand, hosts without matches are hidden, and an empty result says "No servers match "<query>"".
3. **Config error banner** when `configError` is set: red-tinted, the message, a "Reveal Config Folder" button.
4. **Host cards** (`ScrollView` + `LazyVStack(spacing: 12)`), in `hostOrder`:
   - Header: SF Symbol (`Mac` `desktopcomputer`, `Laptop` `laptopcomputer`, prefix `NAS` `externaldrive.connected.to.line.below`, otherwise `server.rack`), host name (headline), "2 of 12 running" (secondary, numeric transition), and a chevron that rotates 90 degrees when expanded. The whole header is one button toggling expansion.
   - Card background: `.background(.background.secondary, in: .rect(cornerRadius: 10))`, the grouped-settings look.
   - Body: server rows separated by hairline dividers (`Divider().padding(.leading, 28)`).
5. **Server row** (constant height for a given content; nothing jumps when state changes):
   - Leading state dot, 8 pt: green running, secondary gray stopped, orange pending (opacity pulse via `phaseAnimator`), tertiary checking, red-outlined hollow no response.
   - Label (body). Below it a caption: `:9996 · Running` (port omitted when nil; `monospacedDigit()`), plus `· mode strip` when a mode is known.
   - When the last action failed: a red caption line "Start failed (exit 1)" with a "Show Log" link button that opens `~/Library/Logs/hummin-menubar-actions.log`. A later success clears it.
   - Trailing: a mode `Picker` (`.menu` style, compact) when `modes` exists. Then the actions:
     - idle and stopped: "Start" (`.borderedProminent`, `.controlSize(.small)`)
     - idle and running: "Restart" and "Stop" (`.bordered`, small)
     - pending: `ProgressView().controlSize(.small)` with the state word, plus "Stop" when `canStop`
   - Mutex: when `mutexSiblings` is non-empty, Start and Restart carry `.help("Also stops: A, B")`.
   - Accessibility: one element per row with label "<label>, port <p>, <state word>"; the buttons stay separately reachable.
6. **Footer:** config path (caption, middle truncation), "Reveal Config" and "Open Logs" buttons.

### Motion

| What | How |
|---|---|
| Expand or collapse a host | `withAnimation(.snappy(duration: 0.28))`, rows `.transition(.opacity.combined(with: .move(edge: .top)))` |
| Counts | `.contentTransition(.numericText())` |
| State dot color | `.animation(.easeOut(duration: 0.2), value: phase)` |
| Pending pulse | `phaseAnimator([0.35, 1.0])` on opacity, 0.8 s |
| Buttons swapping on state change | `.animation(.snappy, value: phase)` |
| Reduce Motion (`accessibilityReduceMotion`) | No pulse, no move transitions, instant expand |

## Preview script

`scripts/preview-window.swift` follows the pattern of `scripts/preview-main.swift`. It builds a `FleetStore` with a canned `CommandRunner` and fixed state (4 hosts, a running row, a pending row, a failed row, a mode row, one expanded host). It renders `FleetView` in an `NSHostingView` inside an offscreen `NSWindow` and captures it with `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`. `ImageRenderer` is not used, because it draws AppKit-backed controls (`Picker(.menu)`, `ProgressView`, bordered buttons, `TextField`, `ScrollView`) as placeholders. The capture needs the GUI session: over ssh, run it as a one-shot LaunchAgent in `gui/$(id -u)`. It produces these PNGs:

- `window-light.png`
- `window-dark.png`
- `window-search.png`

The usage header explains how to compile it with the sources.

## Verification

- `swift build -c release` with zero warnings.
- `swift test` green: `rowState` table, `fleetSummary`, `matches`, `mutexSiblings`, `command(for:on:)`, `sortedServers`, and the `Process` pipe-drain and deadline tests.
- Preview PNGs reviewed.
- Install, then `launchctl print gui/$(id -u)/com.hummin.menubar` shows the job running with no crash exit after 10 minutes.
- One real Start or Stop from the window confirmed in `hummin-menubar-actions.log`.
