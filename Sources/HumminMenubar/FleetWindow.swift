import AppKit
import SwiftUI
#if canImport(FleetCore)
import FleetCore
#endif

// ---- helpers ---------------------------------------------------------------------

private extension ServerAction {
    var title: String { rawValue.capitalized }
}

private func resultWord(_ r: ActionResult) -> String {
    r.exitCode == -1 ? "\(r.action.title) timed out" : "\(r.action.title) failed (exit \(r.exitCode))"
}

private func hostSymbol(_ host: String) -> String {
    switch host {
    case "Mac": return "desktopcomputer"
    case "Laptop": return "laptopcomputer"
    default: return host.hasPrefix("NAS") ? "externaldrive.connected.to.line.below" : "server.rack"
    }
}

private func logsURL(_ name: String) -> URL {
    URL(fileURLWithPath: Config.logsDirectory + "/" + name)
}

private func configFolder(_ store: FleetStore) -> URL {
    let dir = store.configPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hummin-menubar")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func checkedText(_ last: Date?, now: Date) -> String {
    guard let last else { return "Not checked yet" }
    let s = Int(now.timeIntervalSince(last))
    if s < 2 { return "Checked just now" }
    return s < 60 ? "Checked \(s) s ago" : "Checked \(s / 60) min ago"
}

// ---- root --------------------------------------------------------------------------

struct FleetView: View {
    @Bindable var store: FleetStore
    var onClose: () -> Void = {}
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hosts: [String] {
        let extra = store.servers.map(\.host).filter { !store.hostOrder.contains($0) }
        var seen = Set<String>()
        return (store.hostOrder + extra).filter { seen.insert($0).inserted }
    }

    private var grouped: [String: [Server]] { Dictionary(grouping: store.servers, by: \.host) }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            if let error = store.configError { banner(error) }
            list
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(shortcuts)
    }

    // Cmd-F and Esc live in hidden buttons so they work wherever focus is.
    private var shortcuts: some View {
        ZStack {
            Button("Find") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("Close") { if store.query.isEmpty { onClose() } else { store.query = "" } }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private var header: some View {
        let summary = store.servers.isEmpty ? "No servers"
            : fleetSummary(total: store.servers.count, running: runningCount(store.servers, up: store.up), checked: store.lastCheck != nil)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.headline)
                    .contentTransition(.numericText())
                    .animation(Motion.disclosure, value: summary)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(checkedText(store.lastCheck, now: ctx.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.checking { ProgressView().controlSize(.small) }
            Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(HumminIconButtonStyle())
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (\u{2318}R)")
                .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var searchField: some View {
        SearchField(text: $store.query, focused: $searchFocused)
            .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button("Reveal Config Folder") { NSWorkspace.shared.open(configFolder(store)) }
                .buttonStyle(HumminButtonStyle(.secondary))
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var list: some View {
        let groups = grouped
        let searching = !store.query.trimmingCharacters(in: .whitespaces).isEmpty
        let cards: [(host: String, all: [Server], shown: [Server])] = hosts.compactMap { host in
            let all = groups[host] ?? []
            let shown = all.filter { matches($0, query: store.query) }
            return (all.isEmpty || shown.isEmpty) ? nil : (host, all, shown)
        }
        return ScrollView {
            VStack(spacing: 12) {
                if searching && cards.isEmpty {
                    Text("No servers match \u{201C}\(store.query)\u{201D}")
                        .foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(cards, id: \.host) { card in
                    HostCard(store: store, host: card.host, all: card.all, shown: card.shown, forceExpanded: searching)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .animation(reduceMotion ? nil : Motion.disclosure, value: store.query)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(store.configPath ?? "No config loaded")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                if let p = store.configPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                else { NSWorkspace.shared.open(configFolder(store)) }
            } label: { Text("Reveal Config") }
                .buttonStyle(HumminButtonStyle(.quiet, icon: "folder"))
            Button {
                let log = logsURL("hummin-menubar-actions.log")
                if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                else { NSWorkspace.shared.open(URL(fileURLWithPath: Config.logsDirectory)) }
            } label: { Text("Open Logs") }
                .buttonStyle(HumminButtonStyle(.quiet, icon: "doc.text"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

// ---- host card ------------------------------------------------------------------------

private struct HostCard: View {
    let store: FleetStore
    let host: String
    let all: [Server]
    let shown: [Server]
    let forceExpanded: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { forceExpanded || store.expandedHosts.contains(host) }

    var body: some View {
        let countText = "\(runningCount(all, up: store.up)) of \(all.count) running"
        let shape = RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: hostSymbol(host)).frame(width: 20).foregroundStyle(Color.accentColor)
                    Text(host).font(.headline)
                    Text(countText).font(.subheadline).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.disclosure, value: countText)
                    Spacer()
                    ChevronTile(expanded: expanded, hovered: hovered)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(HostHeaderButtonStyle(hovered: hovered))
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.id) { server in
                        Divider().padding(.leading, 30)
                        ServerRow(store: store, server: server)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(.background.secondary, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(Look.cardStroke), lineWidth: Look.cardStrokeWidth))
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Motion.disclosure) {
            if expanded { store.expandedHosts.remove(host) } else { store.expandedHosts.insert(host) }
        }
    }
}

// ---- server row -------------------------------------------------------------------------

private struct StateDot: View {
    let phase: ServerPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch phase {
        case .running: return .green
        case .stopped: return Color(nsColor: .secondaryLabelColor)
        case .checking: return Color(nsColor: .tertiaryLabelColor)
        case .noResponse: return .clear
        case .pending: return .orange
        }
    }

    var body: some View {
        let dot = Circle().fill(color)
            .overlay { if phase == .noResponse { Circle().strokeBorder(Color.red, lineWidth: 1.5) } }
            .frame(width: 8, height: 8)
            .shadow(color: phase == .running ? .green.opacity(0.55) : .clear, radius: 3)
            .animation(.easeOut(duration: 0.2), value: phase)
        if case .pending = phase, !reduceMotion {
            dot.phaseAnimator([0.35, 1.0]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            dot
        }
    }
}

private struct ServerRow: View {
    let store: FleetStore
    let server: Server
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let failed = (store.lastResult[server.id].map { !$0.succeeded } ?? false) && store.pending[server.id] == nil
        let state = rowState(up: store.up[server.id], pending: store.pending[server.id], checked: store.lastCheck != nil)
        let mode = store.modes[server.id]
        let siblings = mutexSiblings(of: server, in: store.servers)
        let also = siblings.isEmpty ? "" : "Also stops: " + siblings.map(\.label).joined(separator: ", ")
        let caption = [server.port.map { ":\($0)" }, state.stateWord, mode].compactMap { $0 }.joined(separator: " \u{00B7} ")

        HStack(spacing: 10) {
            StateDot(phase: state.phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.label)
                Text(caption).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let r = store.lastResult[server.id], !r.succeeded, store.pending[server.id] == nil {
                    HStack(spacing: 6) {
                        Text(resultWord(r)).foregroundStyle(.red)
                        Button("Show Log") { NSWorkspace.shared.open(logsURL("hummin-menubar-actions.log")) }
                            .buttonStyle(HumminButtonStyle(.secondary, compact: true))
                    }
                    .font(.caption)
                    .transition(.opacity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(server.label), \(server.port.map { "port \($0), " } ?? "")\(state.stateWord)")
            Spacer(minLength: 8)
            if let modes = server.modes {
                ModeChip(modes: modes, current: store.pendingMode[server.id] ?? mode ?? "",
                         pending: store.pendingMode[server.id] != nil) { store.setMode($0, on: server) }
            }
            ZStack(alignment: .trailing) {
                // Invisible Restart + Stop pair: sizes the slot so the label column never reflows.
                HStack(spacing: 6) { restart(also: ""); stop }
                    .hidden().accessibilityHidden(true)
                controls(state, also: also)
            }
            .fixedSize()
            .animation(Motion.hover, value: state.phase)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .animation(reduceMotion ? nil : Motion.disclosure, value: failed)
        .background(Color.primary.opacity(hovered ? Look.rowHover : 0))
        .onHover { hovered = $0 }
        .onDisappear { hovered = false }
        .animation(Motion.hover, value: hovered)
    }

    @ViewBuilder
    private func controls(_ state: RowState, also: String) -> some View {
        if case .pending = state.phase {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).accessibilityLabel(state.stateWord)
                if state.canStop { stop }
            }
            .transition(.opacity)
        } else if state.canStart {
            Button("Start") { store.perform(.start, on: server) }
                .buttonStyle(HumminButtonStyle(.primary, icon: "play.fill")).help(also)
                .transition(.opacity)
        } else {
            HStack(spacing: 6) { restart(also: also); stop }.transition(.opacity)
        }
    }

    private func restart(also: String) -> some View {
        Button("Restart") { store.perform(.restart, on: server) }
            .buttonStyle(HumminButtonStyle(.secondary, icon: "arrow.clockwise")).help(also)
    }

    private var stop: some View {
        Button("Stop") { store.perform(.stop, on: server) }
            .buttonStyle(HumminButtonStyle(.secondary, icon: "stop.fill", iconTint: .red))
    }
}
