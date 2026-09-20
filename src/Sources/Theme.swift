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
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.9 : 0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
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
