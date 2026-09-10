import Foundation

/// Resolves Cursor catalog ids and Fast Mode rewrites for the local
/// `cursor-api-proxy` sidecar (Cursor Agent CLI).
///
/// Catalog entries keep a `cursor-` prefix so ThinkingProxy routes them to
/// `127.0.0.1:8320` instead of api.x.ai Grok OAuth.
///
/// Upstream ids match `agent --list-models`:
/// - Composer: `composer-2.5` / `composer-2.5-fast` (no thinking variants)
/// - Grok 4.6: `cursor-grok-4.6-{low,medium,high,xhigh}` plus `-fast`
///
/// Thinking level is **not** baked into the catalog model id. Droid sends
/// `reasoning_effort` and cursor-api-proxy maps it onto the live CLI catalog
/// (`cursor-grok-4.6` + `high` → `cursor-grok-4.6-high`, preserving `-fast`).
enum CursorModelRewriter {
    static let host = CursorAgentProxyManager.proxyHost
    static let port = CursorAgentProxyManager.proxyPort
    static let grok46Family = "cursor-grok-4.6"
    static let composer25Family = "composer-2.5"

    /// Catalog id → Cursor CLI family id (before Fast Mode).
    static let aliases: [String: String] = [
        "cursor-composer-2.5": composer25Family,
        "cursor-grok-4.6": grok46Family,
        "cursor-grok-4.6-fast": "\(grok46Family)-fast",
        "grok-4.6": grok46Family,
        "grok-4.6-fast": "\(grok46Family)-fast"
    ]

    /// Returns the upstream model id to send to cursor-api-proxy.
    static func resolveUpstreamModel(_ catalogModel: String, fastMode: Bool) -> String {
        let aliased = aliases[catalogModel] ?? catalogModel
        return withFastSuffix(aliased, fastMode: fastMode)
    }

    static func withFastSuffix(_ model: String, fastMode: Bool) -> String {
        guard fastMode, !model.hasSuffix("-fast") else { return model }
        return model + "-fast"
    }

    /// Composer 2.5 has no thinking-level variants in the CLI catalog.
    /// Sending Droid's `reasoning_effort` would 400 under STRICT_MODEL.
    static func ignoresReasoningEffort(_ model: String) -> Bool {
        let family = aliases[model] ?? model
        return family == composer25Family || family.hasPrefix("\(composer25Family)-")
    }

    /// Whether Grok OAuth Fast Mode should divert `grok-4.6` to the Cursor CLI proxy.
    static func shouldDivertGrokOAuthToCursorFast(model: String, grok46FastMode: Bool) -> Bool {
        grok46FastMode && (model == "grok-4.6" || model == grok46Family)
    }

    enum CursorFastPathBlocker: Equatable {
        case betaDisabled
        case cursorDisabled
        case agentNotLoggedIn

        var errorMessage: String {
            switch self {
            case .betaDisabled:
                return "Cursor models require Beta mode. Enable Beta in DroidProxy settings."
            case .cursorDisabled:
                return "Cursor provider is disabled in DroidProxy settings."
            case .agentNotLoggedIn:
                return "Cursor Agent CLI is not logged in. Run `agent login` (or Connect under Beta → Cursor)."
            }
        }
    }

    static func cursorFastPathBlocker(
        betaEnabled: Bool,
        cursorEnabled: Bool,
        agentLoggedIn: Bool
    ) -> CursorFastPathBlocker? {
        if !betaEnabled { return .betaDisabled }
        if !cursorEnabled { return .cursorDisabled }
        if !agentLoggedIn { return .agentNotLoggedIn }
        return nil
    }
}
