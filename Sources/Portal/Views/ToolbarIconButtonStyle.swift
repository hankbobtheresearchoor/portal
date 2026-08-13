import SwiftUI

/// Renders one top-right chrome icon in its resolved treatment.
///
/// Like `PortalButtonStyle`, this owns its own metrics and press feedback: a
/// custom `ButtonStyle` receives neither `.controlSize(_:)` nor `.tint(_:)`, and
/// it replaces the system's press highlight, so without a substitute the glyph
/// looks inert when clicked.
internal struct ToolbarIconButtonStyle: ButtonStyle {
    internal let appearance: ToolbarIconAppearance

    /// Icons sit in a row of ten in a narrow title bar, so the footprint is
    /// fixed rather than intrinsic — a treatment that changed the width would
    /// shift every neighbor when the user clicked through the themes.
    private static let side: CGFloat = 26
    private static let glyphSize: CGFloat = 13

    private var treatment: ToolbarIconTreatment { appearance.treatment }

    private var tint: Color {
        switch appearance.tint {
        case .theme: return Theme.accent
        case .neutral: return Theme.primary
        case .muted: return Theme.secondary
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .agent: return Theme.agentAccent
        }
    }

    private var glyphColor: Color {
        switch treatment.glyphFill {
        case .tint: return tint
        case .onTint: return Theme.background
        }
    }

    internal func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Self.glyphSize, weight: .medium))
            .foregroundStyle(glyphColor)
            .padding(treatment.padding)
            .frame(width: Self.side, height: Self.side)
            .background { backdrop }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? treatment.pressedScale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    /// `nil` for the bare treatments, which is what keeps them bare: an empty
    /// shape would still clip the badge overlays the toolbar draws on top.
    @ViewBuilder private var backdrop: some View {
        if let shape = Self.shape(for: treatment.backdrop) {
            ZStack {
                // Outside the clip below — a halo is light spilling past the
                // edge, so clipping it to the shape would erase it.
                if treatment.glowRadius > 0 {
                    shape.fill(tint.opacity(0.45)).blur(radius: treatment.glowRadius)
                }
                ZStack {
                    shape.fill(fill.opacity(treatment.fillOpacity))
                    // Stroked at double width and clipped rather than
                    // `strokeBorder`: that is an `InsettableShape` method and
                    // `AnyShape` erases the insettability.
                    if treatment.borderWidth > 0 {
                        shape.stroke(tint.opacity(0.75), lineWidth: treatment.borderWidth * 2)
                    }
                }
                .clipShape(shape)
            }
        }
    }

    private var fill: Color {
        treatment.fillIsTinted ? tint : Theme.surface
    }

    private static func shape(for backdrop: ToolbarIconBackdrop) -> AnyShape? {
        switch backdrop {
        case .none:
            return nil
        case .circle:
            return AnyShape(Circle())
        case .roundedSquare(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    /// Styles a top-right chrome button in the treatment configured for `slot`,
    /// and attaches the slot's hover tooltip.
    ///
    /// Reads `ThemeManager.shared` internally so each of the ten call sites stays
    /// one line and none of them needs its own `@ObservedObject`. The tooltip
    /// rides here too — icon-only buttons are guessing games without one, and
    /// applying it in the modifier means no call site (or future slot) can
    /// forget it.
    internal func toolbarIcon(_ slot: ToolbarIconSlot) -> some View {
        ToolbarIconModifierBody(content: self, slot: slot)
    }
}

private struct ToolbarIconModifierBody<Content: View>: View {
    internal let content: Content
    internal let slot: ToolbarIconSlot
    @ObservedObject private var themeManager = ThemeManager.shared

    internal var body: some View {
        let appearance = themeManager.toolbarIconAppearance(for: slot)
        // Plain glyphs in the text color are a hand-off, not a treatment: that
        // is what the toolbar looked like before this setting existed, and it
        // has to keep looking exactly that way — down to SwiftUI's own hover and
        // press behavior — for anyone who never opens the pane.
        Group {
            if appearance.treatment == .plain, appearance.tint == .neutral {
                content
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.primary)
            } else {
                content.buttonStyle(ToolbarIconButtonStyle(appearance: appearance))
            }
        }
        .help(slot.helpText)
    }
}
