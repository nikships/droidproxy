import SwiftUI

/// A compact, native-feeling palette for a utility that spends most of its
/// life at the edge of a developer's desktop. The surfaces are deliberately
/// blue-grey rather than neutral black so hierarchy remains visible without
/// drawing boxes around every setting.
enum Theme {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.086)
    static let surface = Color(red: 0.080, green: 0.096, blue: 0.120)
    static let surfaceRaised = Color(red: 0.105, green: 0.125, blue: 0.153)
    static let surfaceHover = Color(red: 0.135, green: 0.157, blue: 0.188)
    static let border = Color.white.opacity(0.055)
    static let borderStrong = Color.white.opacity(0.11)
    static let textPrimary = Color(red: 0.925, green: 0.941, blue: 0.965)
    static let textSecondary = Color(red: 0.620, green: 0.659, blue: 0.712)
    static let textTertiary = Color(red: 0.405, green: 0.443, blue: 0.502)
    /// Warm coral is intentionally reserved for action and a running local proxy.
    static let accent = Color(red: 1.0, green: 0.451, blue: 0.282)
    static let accentBright = Color(red: 1.0, green: 0.570, blue: 0.396)
    static let accentWash = Color(red: 1.0, green: 0.451, blue: 0.282).opacity(0.15)
    static let success = Color(red: 0.357, green: 0.808, blue: 0.633)
    static let danger = Color(red: 1.0, green: 0.405, blue: 0.400)

    static let corner: CGFloat = 8

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

/// A quiet material-like inset used only where a visual grouping genuinely
/// helps comprehension. It intentionally has no permanent border.
struct SurfaceStyle: ViewModifier {
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(focused ? Theme.surfaceHover : Theme.surfaceRaised.opacity(0.72))
            )
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.42), lineWidth: 1)
                }
            }
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}

extension View {
    func surfaceStyle(focused: Bool = false) -> some View {
        modifier(SurfaceStyle(focused: focused))
    }
}

/// Filled utility action. Compact sizing preserves the density expected of a
/// menu-bar companion rather than turning every row into a CTA.
struct PrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(Theme.background.opacity(isEnabled ? 1 : 0.55))
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                Capsule()
                    .fill(isEnabled ? (isHovering ? Theme.accentBright : Theme.accent) : Theme.textTertiary)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.7)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Low-emphasis actions are soft surfaces, not outlined controls.
struct GhostButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(11, weight: .medium))
            .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(isHovering ? Theme.surfaceHover : Theme.surfaceRaised))
            .opacity(configuration.isPressed ? 0.68 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Section headers read like native inspector groups, rather than a numbered
/// marketing sequence. The supplied index is retained for source compatibility.
struct SectionLabel: View {
    let index: String
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
            Text(text)
                .font(Theme.label(11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 2)
    }
}

/// The initial model-install action is intentionally more present than normal
/// row actions, but remains compact and recognisably macOS.
struct ApplyCTAButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(12, weight: .semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(isHovering ? Theme.accentBright : Theme.accent))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CTAArrowGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        Image(systemName: "arrow.right")
            .font(Theme.label(10, weight: .semibold))
            .offset(x: nudge ? 2 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                    nudge = true
                }
            }
    }
}