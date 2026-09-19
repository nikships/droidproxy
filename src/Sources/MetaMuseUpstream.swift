import Foundation

/// Muse Spark is Responses-native. The Muse Code CLI posts `/v1/responses` with
/// `reasoning.effort` and `include: ["reasoning.encrypted_content"]` so later
/// turns can resume thinking. CLIProxyAPI's generic `openai-compatibility`
/// executor translates `/v1/responses` into `/chat/completions` (`chatcmpl-*`
/// ids), which drops encrypted reasoning and breaks long agent runs.
///
/// ThinkingProxy TLS-forwards Muse Responses traffic straight to `api.meta.ai`.
/// Chat Completions still use the compatibility block so multi-account failover
/// keeps working for clients that already speak Completions.
enum MetaMuseUpstream {
    static let apiHost = "api.meta.ai"

    static func isMetaModel(_ model: String?) -> Bool {
        guard let model, !model.isEmpty else { return false }
        return model == "muse-spark-1.3" || model.hasPrefix("muse-spark-1.3-")
    }

    static func isResponsesPath(_ path: String) -> Bool {
        let pathOnly = path.split(separator: "?").first.map(String.init) ?? path
        return pathOnly.contains("/responses")
    }

    static func shouldTLSForward(model: String?, path: String) -> Bool {
        isMetaModel(model) && isResponsesPath(path)
    }

    static func upstreamPath(_ path: String) -> String {
        GrokAuth.normalizeUpstreamPath(path)
    }
}
