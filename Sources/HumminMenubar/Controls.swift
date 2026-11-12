import SwiftUI

// ---- tokens ------------------------------------------------------------------------

private enum Token {
    static let buttonHeight: CGFloat = 24
    static let buttonPadding: CGFloat = 10
    static let buttonIcon: CGFloat = 10
    static let iconGap: CGFloat = 5
    static let buttonLabel: CGFloat = 12
    static let buttonRadius: CGFloat = 7
    static let iconButtonSide: CGFloat = 26
    static let iconButtonSymbol: CGFloat = 13
    static let tileSide: CGFloat = 22
    static let tileRadius: CGFloat = 6
    static let searchRadius: CGFloat = 9
    static let neutral = (rest: 0.07, hover: 0.11, pressed: 0.15)
    static let primary = (rest: 0.18, hover: 0.26, pressed: 0.34)
    static let pressScale: CGFloat = 0.96
    static let disabledOpacity = 0.4
    static let headerHover = 0.035
    static let headerPressed = 0.06
    static let compactHeight: CGFloat = 18
    static let compactLabel: CGFloat = 11
    static let compactIcon: CGFloat = 9
    static let compactPadding: CGFloat = 6
    static let focusOpacity = 0.7
    static let focusWidth: CGFloat = 2
    static let focusOutset: CGFloat = 3
    static let chipChevron: CGFloat = 8
    static let tileChevron: CGFloat = 10
    static let searchFill = (rest: 0.05, focused: 0.03)
    static let searchStroke = (opacity: 0.6, width: 1.5)
    static let searchGap: CGFloat = 6
    static let searchPadding = (h: CGFloat(10), v: CGFloat(7))
}

/// Values FleetWindow shares with the controls.
enum Look {
    static let cardRadius: CGFloat = 12
    static let cardStroke = 0.08
    static let cardStrokeWidth: CGFloat = 0.5
    static let rowHover = 0.035
}

enum Motion {
    static let disclosure = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.25)
    static let flip = Animation.spring(response: 0.32, dampingFraction: 0.62)
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.6)
    static let hover = Animation.easeOut(duration: 0.15)
}

private func neutralFill(hovered: Bool, pressed: Bool = false) -> Color {
    Color.primary.opacity(pressed ? Token.neutral.pressed : hovered ? Token.neutral.hover : Token.neutral.rest)
}

// ---- buttons -----------------------------------------------------------------------

private struct ButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: HumminButtonStyle.Role
    var icon: String?
    var iconTint: Color?
    var compact = false
    var square: CGFloat?
    var trailingIcon: String?

    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pressed: Bool { configuration.isPressed && enabled }
    private var hot: Bool { hovered && enabled }
    private var radius: CGFloat { Token.buttonRadius }

    private var fill: Color {
        if role == .primary {
            return Color.accentColor.opacity(pressed ? Token.primary.pressed : hot ? Token.primary.hover : Token.primary.rest)
        }
        if role == .quiet && !hot && !pressed { return .clear }
        return neutralFill(hovered: hot, pressed: pressed)
    }

    private var labelColor: Color { role == .quiet && !hot ? .secondary : .primary }

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius + Token.focusOutset, style: .continuous)
                        .stroke(Color.accentColor.opacity(Token.focusOpacity), lineWidth: Token.focusWidth).padding(-Token.focusOutset)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(pressed && !reduceMotion ? Token.pressScale : 1)
            .opacity(enabled ? 1 : Token.disabledOpacity)
            .animation(Motion.hover, value: hot)
            .animation(Motion.press, value: pressed)
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
    }

    @ViewBuilder
    private var content: some View {
        if let square {
            configuration.label
                .font(.system(size: Token.iconButtonSymbol, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: square, height: square)
        } else {
            HStack(spacing: Token.iconGap) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? Token.compactIcon : Token.buttonIcon, weight: .semibold))
                        .foregroundStyle(iconTint ?? (role == .primary ? Color.accentColor : labelColor))
                }
                configuration.label
                    .font(.system(size: compact ? Token.compactLabel : Token.buttonLabel, weight: .medium))
                    .foregroundStyle(labelColor)
                    .fixedSize()
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: Token.chipChevron, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, compact ? Token.compactPadding : Token.buttonPadding)
            .frame(height: compact ? Token.compactHeight : Token.buttonHeight)
        }
    }
}

struct HumminButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, quiet }
    let role: Role
    var icon: String?
    var iconTint: Color?
    var compact = false
    var trailingIcon: String?

    init(_ role: Role, icon: String? = nil, iconTint: Color? = nil, compact: Bool = false, trailingIcon: String? = nil) {
        self.role = role; self.icon = icon; self.iconTint = iconTint; self.compact = compact; self.trailingIcon = trailingIcon
    }

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, role: role, icon: icon, iconTint: iconTint, compact: compact, trailingIcon: trailingIcon)
    }
}

struct HumminIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, role: .secondary, square: Token.iconButtonSide)
    }
}

// ---- host header -------------------------------------------------------------------

struct HostHeaderButtonStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? Token.headerPressed : hovered ? Token.headerHover : 0))
            .animation(Motion.hover, value: hovered)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

struct ChevronTile: View {
    let expanded: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: Token.tileChevron, weight: .bold))
            .foregroundStyle(hovered ? Color.primary : Color.secondary)
            // Scoped to the rotation: a value-keyed .animation would also spring the glyph's position
            // and split it from the tile whenever the header moves while it flips (search filtering).
            .animation(reduceMotion ? Motion.hover : Motion.flip) { $0.rotationEffect(.degrees(expanded ? 90 : 0)) }
            .frame(width: Token.tileSide, height: Token.tileSide)
            .background(RoundedRectangle(cornerRadius: Token.tileRadius, style: .continuous).fill(neutralFill(hovered: hovered)))
            .animation(Motion.hover, value: hovered)
    }
}

// ---- mode chip ---------------------------------------------------------------------

struct ModeChip: View {
    let modes: [String]
    let current: String
    let pending: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(modes, id: \.self) { mode in
                Button { onSelect(mode) } label: {
                    if mode == current { Label(mode, systemImage: "checkmark") } else { Text(mode) }
                }
            }
        } label: {
            Text(current.isEmpty ? "Mode" : current)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HumminButtonStyle(.secondary, trailingIcon: "chevron.up.chevron.down"))
        .fixedSize()
        .disabled(pending)
        .accessibilityLabel("Mode")
        .accessibilityValue(current)
    }
}

// ---- search ------------------------------------------------------------------------

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    @State private var clearHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Token.searchRadius, style: .continuous)
        HStack(spacing: Token.searchGap) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter servers", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).opacity(clearHovered ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .onHover { clearHovered = $0 }
                .onDisappear { clearHovered = false }
                .animation(Motion.hover, value: clearHovered)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Token.searchPadding.h).padding(.vertical, Token.searchPadding.v)
        .background(shape.fill(Color.primary.opacity(focused.wrappedValue ? Token.searchFill.focused : Token.searchFill.rest)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(Token.searchStroke.opacity), lineWidth: Token.searchStroke.width).opacity(focused.wrappedValue ? 1 : 0))
        .animation(Motion.hover, value: focused.wrappedValue)
    }
}
