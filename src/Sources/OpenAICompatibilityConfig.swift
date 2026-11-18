import Foundation

/// Builds the single top-level `openai-compatibility:` block of the merged
/// CLIProxyAPI config. The backend's YAML parser rejects a repeated mapping key,
/// so every provider that routes through this mechanism (Meta Muse, Mistral)
/// contributes an `Entry` here instead of writing the key itself.
enum OpenAICompatibilityConfig {
    struct Entry: Equatable {
        /// Names the provider in the comment above the block, e.g. "Meta Muse subscription".
        let comment: String
        let name: String
        let baseURL: String
        let apiKeys: [String]
        let models: [String]
    }

    /// Returns "" when no entry has keys. JSON strings are valid YAML scalars,
    /// including quotes and control characters, so every value is JSON-encoded.
    static func render(_ entries: [Entry]) -> String {
        let active = entries.filter { !$0.apiKeys.isEmpty }
        guard !active.isEmpty else { return "" }

        var lines = [""]
        lines += active.map { "# \($0.comment) (auto-added by DroidProxy)" }
        lines.append("openai-compatibility:")
        for entry in active {
            lines.append("  - name: \(quoted(entry.name))")
            lines.append("    base-url: \(quoted(entry.baseURL))")
            lines.append("    api-key-entries:")
            lines += entry.apiKeys.map { "      - api-key: \(quoted($0, escapingSlashes: true))" }
            lines.append("    models:")
            lines += entry.models.map { "      - name: \(quoted($0))" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Keys keep the default encoder (it writes `/` as `\/`, a valid YAML escape) so the
    /// Meta-only output stays byte-identical to what DroidProxy wrote before this builder.
    private static func quoted(_ value: String, escapingSlashes: Bool = false) -> String {
        let encoder = JSONEncoder()
        if !escapingSlashes { encoder.outputFormatting = .withoutEscapingSlashes }
        // Encoding a String cannot fail.
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
}
