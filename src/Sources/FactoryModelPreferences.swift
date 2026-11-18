import Foundation

/// Per-model Factory opt-outs. An empty set means every catalog model is on,
/// matching the behavior before model-level switches existed.
enum FactoryModelPreferences {
    static let disabledModelSlugsKey = "disabledFactoryModelSlugs"

    static func disabledModelSlugs(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(normalized(defaults.stringArray(forKey: disabledModelSlugsKey) ?? []))
    }

    static func isEnabled(slug: String, in defaults: UserDefaults = .standard) -> Bool {
        !disabledModelSlugs(in: defaults).contains(normalizedSlug(slug))
    }

    @discardableResult
    static func setEnabled(
        _ enabled: Bool,
        slug: String,
        in defaults: UserDefaults = .standard
    ) -> Set<String> {
        let slug = normalizedSlug(slug)
        var disabled = disabledModelSlugs(in: defaults)
        if !slug.isEmpty {
            if enabled {
                disabled.remove(slug)
            } else {
                disabled.insert(slug)
            }
            defaults.set(disabled.sorted(), forKey: disabledModelSlugsKey)
        }
        return disabled
    }

    private static func normalized(_ slugs: [String]) -> [String] {
        var seen = Set<String>()
        return slugs.compactMap { slug in
            let normalized = normalizedSlug(slug)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizedSlug(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model-level opt-out follows the replacement, just like Fast Mode.
        switch trimmed {
        case "gpt-6-astra": return "gpt-6.2-astra"
        case "gpt-6.1-sol": return "gpt-6.2-sol"
        default: return trimmed
        }
    }
}
