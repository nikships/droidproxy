import SwiftUI

struct ProviderBrandSwatch: Equatable, Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    func scaled(by factor: Double) -> ProviderBrandSwatch {
        ProviderBrandSwatch(
            red: UInt8(clamping: Int((Double(red) * factor).rounded())),
            green: UInt8(clamping: Int((Double(green) * factor).rounded())),
            blue: UInt8(clamping: Int((Double(blue) * factor).rounded()))
        )
    }
}

/// Fixed ring colors for every provider. Popularity is a judgment call about
/// how widely each product is used, and the assignment always runs over the
/// full catalog so it does not change when an account is disconnected.
enum ProviderUsageColors {
    /// Most popular first. A shared swatch is kept by the earlier provider.
    static let popularity: [ServiceType] = [
        .codex,        // ChatGPT
        .claude,
        .antigravity,  // Gemini
        .copilot,
        .grok,
        .meta,         // Muse
        .kimi,
        .junie,
    ]

    /// Primary, then secondary, then a further brand color. Primaries match the Settings toggles.
    static let palettes: [ServiceType: [ProviderBrandSwatch]] = [
        .codex: [
            ProviderBrandSwatch(red: 0x74, green: 0xAA, blue: 0x9C),
            ProviderBrandSwatch(red: 0x10, green: 0xA3, blue: 0x7F),
            ProviderBrandSwatch(red: 0x0D, green: 0x6E, blue: 0x56),
        ],
        .claude: [
            ProviderBrandSwatch(red: 0xD9, green: 0x77, blue: 0x57),
            ProviderBrandSwatch(red: 0xC4, green: 0x5C, blue: 0x38),
            ProviderBrandSwatch(red: 0x8C, green: 0x3E, blue: 0x28),
        ],
        .antigravity: [
            ProviderBrandSwatch(red: 0x42, green: 0x85, blue: 0xF4),
            ProviderBrandSwatch(red: 0x34, green: 0xA8, blue: 0x53),
            ProviderBrandSwatch(red: 0xEA, green: 0x43, blue: 0x35),
        ],
        .copilot: [
            ProviderBrandSwatch(red: 0x77, green: 0xB9, blue: 0xFF),
            ProviderBrandSwatch(red: 0x82, green: 0x50, blue: 0xDF),
            ProviderBrandSwatch(red: 0x2D, green: 0xA4, blue: 0x4E),
        ],
        .grok: [
            ProviderBrandSwatch(red: 0x1D, green: 0x9B, blue: 0xF0),
            ProviderBrandSwatch(red: 0x0A, green: 0x6C, blue: 0x9E),
            ProviderBrandSwatch(red: 0x5C, green: 0xC8, blue: 0xF5),
        ],
        .meta: [
            ProviderBrandSwatch(red: 0x08, green: 0x66, blue: 0xFF),
            ProviderBrandSwatch(red: 0x6C, green: 0x3C, blue: 0xE0),
            ProviderBrandSwatch(red: 0xE0, green: 0x3C, blue: 0x8A),
        ],
        .kimi: [
            ProviderBrandSwatch(red: 0x00, green: 0xBF, blue: 0x91),
            ProviderBrandSwatch(red: 0x0E, green: 0x7C, blue: 0x6B),
            ProviderBrandSwatch(red: 0x5B, green: 0xE0, blue: 0xC2),
        ],
        .junie: [
            ProviderBrandSwatch(red: 0x48, green: 0xE0, blue: 0x54),
            ProviderBrandSwatch(red: 0x1F, green: 0x8F, blue: 0x3A),
            ProviderBrandSwatch(red: 0x08, green: 0x7C, blue: 0xFA),
        ],
    ]

    static func color(for provider: ServiceType) -> Color {
        swatch(for: provider).color
    }

    static func swatch(for provider: ServiceType) -> ProviderBrandSwatch {
        assignment[provider]
            ?? palettes[provider]?.first
            ?? ProviderBrandSwatch(red: 0x8E, green: 0x8E, blue: 0x93)
    }

    static let assignment: [ServiceType: ProviderBrandSwatch] = resolve(
        popularity: popularity,
        palettes: palettes
    )

    static func resolve(
        popularity: [ServiceType],
        palettes: [ServiceType: [ProviderBrandSwatch]]
    ) -> [ServiceType: ProviderBrandSwatch] {
        var claimed = Set<ProviderBrandSwatch>()
        var assigned: [ServiceType: ProviderBrandSwatch] = [:]
        let extras = palettes.keys.filter { !popularity.contains($0) }
        for provider in popularity + extras {
            guard let chosen = firstUnclaimed(in: palettes[provider] ?? [], claimed: claimed) else { continue }
            assigned[provider] = chosen
            claimed.insert(chosen)
        }
        return assigned
    }

    private static func firstUnclaimed(
        in palette: [ProviderBrandSwatch],
        claimed: Set<ProviderBrandSwatch>
    ) -> ProviderBrandSwatch? {
        if let free = palette.first(where: { !claimed.contains($0) }) {
            return free
        }
        guard let last = palette.last else { return nil }
        for step in 1...8 {
            let factor = max(0.15, 1 - (0.18 * Double(step)))
            let darkened = last.scaled(by: factor)
            if !claimed.contains(darkened) {
                return darkened
            }
        }
        for salt in 1...240 {
            let nudged = ProviderBrandSwatch(
                red: last.red &+ UInt8(salt),
                green: last.green,
                blue: last.blue
            )
            if !claimed.contains(nudged) {
                return nudged
            }
        }
        return last
    }
}
