# hummin-menubar window design contract

The menubar app is a status item that opens one native window: the fleet. The dropdown menu it replaces became unusable at 45 servers across 4 hosts. The window's structure follows the hummin page in the NixOS settings shell (serpantinum `quickshell/guide/HumminTab.qml`): host cards that expand and collapse, and server rows with state, port, mode and inline actions. It uses native macOS materials and type, with its own controls (see Controls).

## Rules

1. **UX first.** One glance answers "what is running, where, and did my last action work?" Failures are shown in the row, not only in a log file.
2. **Native frame, crafted controls.** SwiftUI inside an `NSWindow`, SF Symbols, system font, system accent (`Color.accentColor`), automatic light and dark. Buttons, the disclosure chevron, the mode chip and the search field are custom styles defined in Controls; no `.bordered`, `.borderedProminent`, `.link` or `Picker(.menu)` remains. Colors are the accent, `Color.primary` at the opacities in Controls, and the status tones (green running, orange pending, red failed). A tone always comes with a word.
3. **Behavior parity.** Action semantics, mutex groups, mode switching, health checks, timeouts and log formats are unchanged from the dropdown, and `servers.json` stays byte-compatible with the Linux app.
4. **Energy.** Health checks run only while the window is visible, plus once at launch. Nothing polls in the background.
5. **Every motion is smooth or absent.** Nothing jumps, slides through a clip, or snaps mid-animation. Every height change (expand, collapse, search filtering, a failed-action line appearing or clearing) animates with `Motion.disclosure`. Reduce Motion removes scale, overshoot and height animation, and keeps short fades.

## Targets

`Package.swift` uses swift-tools 5.9 and platform macOS 14 (`@Observable`, `phaseAnimator`). There are three targets:

- `FleetCore` (library, `Sources/FleetCore`): `Config.swift`, `Process.swift` and `FleetModel.swift`. Foundation only, no AppKit or SwiftUI.
- `HumminMenubar` (executable, `Sources/HumminMenubar`): `main.swift`, `Bird.swift`, `FleetStore.swift`, `FleetWindow.swift`, `Controls.swift` and `Resources/`. Depends on `FleetCore`.
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

1. **Header row:** the fleet summary ("12 of 45 running", `.contentTransition(.numericText())`), "Checked 3 s ago" (`TimelineView(.periodic(from:by: 1))`), a small `ProgressView` while checking, and a Refresh icon button (`HumminIconButtonStyle`, `arrow.clockwise`, Cmd-R).
2. **Search field** (`SearchField` in Controls): magnifying glass prefix, placeholder "Filter servers", Cmd-F focuses it. With a query, hosts with matches auto-expand, hosts without matches are hidden, and an empty result says "No servers match "<query>"". Query changes (typing, clear button, Esc) animate the cards and rows with `Motion.disclosure` (`nil` under Reduce Motion), so the chevron's spring and the card's height move together.
3. **Config error banner** when `configError` is set: red-tinted, the message, a "Reveal Config Folder" button (`.secondary` role).
4. **Host cards** (`ScrollView` + `VStack(spacing: 12)`, not `LazyVStack`: a lazy stack does not animate the cards below a resizing card, they jump), in `hostOrder`:
   - Header: SF Symbol in the accent color (`Mac` `desktopcomputer`, `Laptop` `laptopcomputer`, prefix `NAS` `externaldrive.connected.to.line.below`, otherwise `server.rack`), host name (headline), "2 of 12 running" (secondary, numeric transition), and the `ChevronTile` on the trailing edge. The whole header is one button toggling expansion (`HostHeaderButtonStyle`).
   - Card: `.background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))`, a 0.5 pt `Color.primary.opacity(0.08)` stroke on the same shape, and `.clipShape` with the same shape.
   - Body: server rows separated by hairline dividers (`Divider().padding(.leading, 30)`), inserted and removed as in Motion.
5. **Server row** (constant height for a given content; nothing jumps when state changes):
   - Hover: the row gets a `Color.primary.opacity(0.035)` background (full card width), faded in and out per Motion.
   - Leading state dot, 8 pt: green running (with a soft glow: `.shadow(color: .green.opacity(0.55), radius: 3)`), secondary gray stopped, orange pending (opacity pulse via `phaseAnimator`), tertiary checking, red-outlined hollow no response.
   - Label (body). Below it a caption: `:9996 · Running` (port omitted when nil; `monospacedDigit()`), plus `· mode strip` when a mode is known.
   - When the last action failed: a red caption line "Start failed (exit 1)" with a "Show Log" button (`HumminButtonStyle(.secondary, compact: true)`: 18 pt high, 11 pt label, 6 pt padding, neutral fill so it reads as a button) that opens `~/Library/Logs/hummin-menubar-actions.log`. A later success clears it. The line enters and leaves with `.transition(.opacity)` while the row height animates with `Motion.disclosure`.
   - Trailing: the `ModeChip` when `modes` exists. Then the actions, each `HumminButtonStyle` with an icon:
     - idle and stopped: "Start" (`.primary`, `play.fill`)
     - idle and running: "Restart" (`.secondary`, `arrow.clockwise`) and "Stop" (`.secondary`, `stop.fill`, icon tinted red)
     - pending: `ProgressView().controlSize(.small)` with `.accessibilityLabel(state.stateWord)`, plus "Stop" when `canStop`. No visible state word here: the caption already says "Starting...".
     - The trailing actions sit in a fixed-width trailing slot sized for "Restart" + "Stop", right-aligned, so the label column never reflows when the buttons swap.
   - Mutex: when `mutexSiblings` is non-empty, Start and Restart carry `.help("Also stops: A, B")`.
   - Accessibility: one element per row with label "<label>, port <p>, <state word>"; the buttons stay separately reachable.
6. **Footer:** config path (caption, middle truncation), "Reveal Config" (`folder`) and "Open Logs" (`doc.text`) as `.quiet` buttons.

## Controls

All in a new file `Sources/HumminMenubar/Controls.swift` (add it to the preview script's copy list). Tokens are `private` constants at the top of that file, not scattered literals.

| Token | Value |
|---|---|
| button height | 24 pt |
| button horizontal padding | 10 pt (8 pt with icon only) |
| button icon | 10 pt `.semibold` SF Symbol, 5 pt gap to the label |
| button label | 12 pt `.medium` |
| button radius | 7 pt, `.continuous` |
| neutral fill rest / hover / pressed | `Color.primary.opacity(0.07 / 0.11 / 0.15)` |
| primary fill rest / hover / pressed | `Color.accentColor.opacity(0.18 / 0.26 / 0.34)` |
| focus ring | 2 pt `Color.accentColor.opacity(0.7)` stroke, 3 pt outside the shape, shown when the button has keyboard focus (`@Environment(\.isFocused)`). Exactly one ring: if the system ring also draws, suppress it with `.focusEffectDisabled()` only where our ring is proven to show. |
| disabled | whole button at opacity 0.4, no hover or press response |

`struct HumminButtonStyle: ButtonStyle` with `enum Role { case primary, secondary, quiet }`, plus optional `icon: String?` and `iconTint: Color?`:

- `.primary`: primary fill, icon in the accent color, label in `Color.primary`. The label stays `.primary` on purpose: accent-colored small text on a light fill is under 4.5:1 for the default blue.
- `.secondary`: neutral fill, icon and label in `Color.primary` (icon in `iconTint` when given).
- `.quiet`: no fill at rest, label and icon `.secondary`; hover shows the neutral hover fill and turns the label `.primary`.
- Hover is tracked inside the style's body view with `.onHover`; press is `configuration.isPressed`.
- Press: scale 0.96. Release springs back with a slight overshoot (the click "pop"). No scale on hover: scaled text re-rasterizes and looks soft on macOS.
- Hit area: the full rounded rect (`.contentShape`).

`struct HumminIconButtonStyle: ButtonStyle`: a 26 pt square of the `.secondary` look holding only a symbol (13 pt `.medium`). Used for Refresh.

`ChevronTile` (the reference's `FlipIcon`): a 22 pt rounded square (radius 6, continuous) with the neutral fill, holding `chevron.right` (10 pt `.bold`, `.secondary`, `.primary` on header hover). It rotates 0 to 90 degrees when expanded. It is decoration inside the header button, not its own button; it reads hover from the header (pass a `hovered: Bool`). Hover: neutral hover fill.

`HostHeaderButtonStyle`: the whole header row. Hover background `Color.primary.opacity(0.035)`; press darkens to 0.06. No scale (the card is too large to scale cleanly).

`ModeChip`: replaces `Picker(.menu)`. It must look exactly like a `.secondary` `HumminButtonStyle` button: neutral fill 24 pt high, radius 7, label "strip" at 12 pt `.medium` in `Color.primary`, then `chevron.up.chevron.down` (8 pt, `.secondary`) trailing the label, same hover and press response. `.menuStyle(.borderlessButton)` does not achieve this (it re-lays out the label: bold text, icon leading, fill 13 px tall). Use whichever of these renders correctly on macOS 14+, verified in the PNG: (a) `Menu` with `.menuStyle(.button)` and `.buttonStyle(HumminButtonStyle(.secondary))`; (b) the chip drawn in SwiftUI with the `Menu` laid over it as the hit target. The menu lists the modes with a checkmark on the current one. Disabled while `pendingMode` is set, with the label showing the pending mode. Accessibility: label "Mode", value the current mode.

`SearchField`: the existing field (magnifying glass, plain `TextField`, clear button) on a `Color.primary.opacity(0.05)` rounded rect (radius 9, continuous). When focused: a 1.5 pt `Color.accentColor.opacity(0.6)` stroke and the fill at 0.03, both animated per Motion. The clear button uses `.buttonStyle(.plain)` with a hover opacity change.

### Motion

Curves are named constants in `Controls.swift` so every view shares them:

- `Motion.disclosure = .timingCurve(0.33, 1, 0.68, 1, duration: 0.25)` (ease-out cubic, the reference's `Easing.OutCubic` 250 ms)
- `Motion.flip = .spring(response: 0.32, dampingFraction: 0.62)` (overshoot, the reference's `Easing.OutBack`)
- `Motion.press = .spring(response: 0.22, dampingFraction: 0.6)` (press in, pop out)
- `Motion.hover = .easeOut(duration: 0.15)`

| What | How |
|---|---|
| Expand or collapse a host | `withAnimation(Motion.disclosure)` around the `expandedHosts` change. The rows block is inserted with `.transition(.opacity)` only. The card's height animates through layout, and the card's `clipShape` reveals the rows top-down as it grows (the reference's `height = content x openProgress` with `clip: true`). |
| Chevron | rotation 0 to 90 degrees with `Motion.flip`, driven by the same `expanded` value |
| Hover fills (buttons, header, rows, chip, tile) | `Motion.hover` |
| Press | scale 0.96 and pressed fill with `Motion.press`; release uses the same spring (overshoot gives the pop) |
| Search focus | stroke and fill with `Motion.hover` |
| Counts | `.contentTransition(.numericText())` |
| State dot color | `.animation(.easeOut(duration: 0.2), value: phase)` |
| Pending pulse | `phaseAnimator([0.35, 1.0])` on opacity, 0.8 s |
| Buttons swapping on state change | `.transition(.opacity)` inside the fixed trailing slot, `.animation(Motion.hover, value: phase)` |
| Reduce Motion (`accessibilityReduceMotion`) | Instant expand and collapse (`nil` animation), chevron rotates with `Motion.hover`, no press scale, no pulse. Hover and focus fades stay. |

Why the old disclosure looked broken, so it does not come back:

- `LazyVStack` sized the cards below the toggled card without animating them, so they jumped while the toggled card animated.
- `.move(edge: .top)` slid the rows from above the card while the card's clip grew at the same time: two motions fighting through one clip.
- The chevron and the rows ran the same `.snappy` curve twice (an `.animation` modifier and a `withAnimation`); one source now.

## Preview script

`scripts/preview-window.swift` follows the pattern of `scripts/preview-main.swift`. It builds a `FleetStore` with a canned `CommandRunner` and fixed state (4 hosts, a running row, a pending row, a failed row, a mode row, one expanded host). It renders `FleetView` in an `NSHostingView` inside an offscreen `NSWindow` and captures it with `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`. `ImageRenderer` is not used, because it draws AppKit-backed controls (`Picker(.menu)`, `ProgressView`, bordered buttons, `TextField`, `ScrollView`) as placeholders. The capture needs the GUI session: over ssh, run it as a one-shot LaunchAgent in `gui/$(id -u)`. It produces these PNGs:

- `window-light.png`
- `window-dark.png`
- `window-search.png`
- `expand-0.png` ... `expand-6.png`: the Mac card collapsed, then `withAnimation(Motion.disclosure)` expands it and the window is captured at about 0, 40, 80, 125, 170, 250 and 400 ms (spin the run loop between captures). The frames show whether the card grows monotonically and the cards below follow without a jump. If the capture does not reflect in-flight animation state (all middle frames equal the first or the last), the script prints that instead of claiming a filmstrip.
- `collapse-0.png` ... `collapse-6.png`: the same capture for collapsing the expanded Mac card.
- `search-0.png` ... `search-6.png`: the same capture while the query changes from empty to "99" (cards hide and auto-expand together).

The usage header explains how to compile it with the sources.

## Verification

- `swift build -c release` with zero warnings.
- `swift test` green: `rowState` table, `fleetSummary`, `matches`, `mutexSiblings`, `command(for:on:)`, `sortedServers`, and the `Process` pipe-drain and deadline tests.
- Preview PNGs reviewed, in light and dark, including the expand frames.
- `grep -nE 'borderedProminent|\.bordered\b|buttonStyle\(\.link\)|pickerStyle|LazyVStack|move\(edge' Sources/` returns nothing.
- Install, then `launchctl print gui/$(id -u)/com.hummin.menubar` shows the job running with no crash exit after 10 minutes.
- One real Start or Stop from the window confirmed in `hummin-menubar-actions.log`.
