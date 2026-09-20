import SwiftUI

/// Factory design tokens, matching factory.ai's dark product surfaces:
/// #020202 base, #101010 raised, #EEE text, Factory orange accent,
/// monospace uppercase labels, near-square corners, hairline borders.
enum Theme {
    static let background = Color(red: 0.008, green: 0.008, blue: 0.008)   // #020202
    static let surface = Color(red: 0.039, green: 0.039, blue: 0.039)      // #0A0A0A
    static let surfaceRaised = Color(red: 0.063, green: 0.063, blue: 0.063) // #101010
    static let border = Color.white.opacity(0.09)
    static let borderStrong = Color.white.opacity(0.18)
    static let textPrimary = Color(red: 0.933, green: 0.933, blue: 0.933)  // #EEEEEE
    static let textSecondary = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let textTertiary = Color.white.opacity(0.32)
    static let accent = Color(red: 0.933, green: 0.376, blue: 0.094)       // #EE6018
    static let accentBright = Color(red: 0.937, green: 0.435, blue: 0.18)  // #EF6F2E
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)

    static let corner: CGFloat = 3

    /// Monospace UI text, Factory's uppercase label/button treatment.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Flat near-black panel with a hairline border, used for editors and results.
struct SurfaceStyle: ViewModifier {
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(
                        focused ? Theme.accent.opacity(0.6) : Theme.border,
                        lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension View {
    func surfaceStyle(focused: Bool = false) -> some View {
        modifier(SurfaceStyle(focused: focused))
    }
}

/// Primary action button: light fill, black uppercase mono label,
/// like factory.ai's "START BUILDING →" CTA on dark sections.
/// Use `compact: true` for primary buttons embedded inside table rows
/// ("Add Account", "Connect") so they don't overpower the row.
struct PrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(compact ? 10 : 12, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.9 : 0.5))
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 5 : 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(isEnabled
                        ? (isHovering ? Color.white : Theme.textPrimary)
                        : Color.white.opacity(0.25))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet bordered button: dark fill, hairline border, uppercase mono label.
/// Hover shifts the border and text toward Factory orange, as on factory.ai.
struct GhostButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(11, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(isHovering ? Theme.accentBright : Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(
                        isHovering ? Theme.accent.opacity(0.7) : Theme.borderStrong,
                        lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Factory-style numbered eyebrow: "01 / PROMPT" in uppercase mono with an
/// orange index, matching the section headers on factory.ai.
struct SectionLabel: View {
    let index: String
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text(index)
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text.uppercased())
                .font(Theme.mono(10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Hero CTA for the Factory custom-models Apply action. Same light-filled
/// inversion as factory.ai's "START BUILDING →", plus a quiet attract loop:
/// a Factory-orange hairline scans along the button's bottom edge while the
/// trailing arrow (`CTAArrowGlyph`) breathes. Hover brightens the fill and
/// the arrow starts nudging; pressing flashes the fill to the bright accent,
/// scales the button down slightly, and fires a fast scanner wipe across it.
/// All motion is mechanical easeOut/linear — no springs, no shimmer.
struct ApplyCTAButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Color.black.opacity(0.9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .fill(configuration.isPressed
                                ? Theme.accentBright
                                : (isHovering ? Color.white : Theme.textPrimary))
                        ScanLine(width: geo.size.width)
                        PressWipe(width: geo.size.width, pressed: configuration.isPressed)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(
                        configuration.isPressed ? Theme.accent : Theme.borderStrong,
                        lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

/// A Factory-orange hairline that repeatedly scans the button's bottom edge,
/// entering from the left and exiting at the right. Static (parked offscreen)
/// under Reduce Motion.
private struct ScanLine: View {
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var running = false

    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 26, height: 1.5)
            .offset(x: running ? width + 26 : -26, y: -1)
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 2.6).repeatForever(autoreverses: false),
                value: running)
            .onAppear { running = true }
    }
}

/// One-shot dark scanner wipe fired when the button goes down. Sweeps a flat
/// translucent-black segment left→right in 0.26s, then parks until the next
/// press. Disabled under Reduce Motion.
private struct PressWipe: View {
    let width: CGFloat
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    private var segmentWidth: CGFloat { max(22, width * 0.3) }

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.16))
            .frame(width: segmentWidth)
            .offset(x: sweeping ? width : -segmentWidth)
            .allowsHitTesting(false)
            .onChange(of: pressed) { down in
                guard down, !reduceMotion else { return }
                sweeping = true
                withAnimation(.easeOut(duration: 0.26)) { sweeping = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { sweeping = false }
            }
    }
}

/// Trailing arrow for the Apply CTA. Breathes slowly at rest (0→2pt); while
/// hovered it switches to a quicker, longer nudge (0→3.5pt) — as if impatient
/// to go. Static under Reduce Motion.
struct CTAArrowGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var phase: CGFloat = 0

    var body: some View {
        Image(systemName: "arrow.right")
            .font(Theme.mono(10, weight: .semibold))
            .offset(x: phase)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: isHovering ? 0.4 : 1.8).repeatForever(autoreverses: true),
                value: phase)
            .onAppear {
                guard !reduceMotion else { return }
                phase = 2
            }
            .onHover { hovering in
                guard !reduceMotion else { return }
                isHovering = hovering
                // Reset without animating so the loop always oscillates from 0.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { phase = 0 }
                phase = hovering ? 3.5 : 2
            }
    }
}
