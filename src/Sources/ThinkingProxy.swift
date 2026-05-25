import Foundation
import Network

/**
 A lightweight HTTP proxy that forwards Claude / Codex / Gemini / Kimi requests to the
 local CLIProxyAPI backend. Droid CLI controls per-session reasoning effort via Factory
 custom-model metadata, so this proxy no longer injects reasoning or thinking fields
 into request bodies. It still:

 - Rewrites the Anthropic-Beta header to drop `redact-thinking-2026-02-12` when a Claude
   request enables thinking, so Claude emits visible thinking blocks.
 - Injects `service_tier: "priority"` for OpenAI Responses API requests on the user-enabled
   GPT 5.x fast-mode models (these toggles are independent of reasoning effort).
 - Forwards Amp CLI auth/management paths to ampcode.com and normalizes the response.
 - Rewrites Gemini `/v1/responses` to `/v1/chat/completions` since the backend does not
   support Gemini via the Responses API endpoint.

 JSON edits are surgical (no re-serialization) so Anthropic prompt-cache key ordering is
 preserved.
 */
class ThinkingProxy {
    private var listener: NWListener?
    let proxyPort: UInt16 = 8317
    private let targetPort: UInt16 = 8318
    private let targetHost = "127.0.0.1"
    private(set) var isRunning = false
    private let stateQueue = DispatchQueue(label: "io.automaze.droidproxy.thinking-proxy-state")

    /// File-based debug logger (writes to /tmp/droidproxy-debug.log)
    private static let logFile: URL = URL(fileURLWithPath: "/tmp/droidproxy-debug.log")
    private static let logQueue = DispatchQueue(label: "io.automaze.droidproxy.file-log")
    private static let logTimestampFormatter = ISO8601DateFormatter()

    static func fileLog(_ message: String) {
        let date = Date()
        logQueue.async {
            let timestamp = logTimestampFormatter.string(from: date)
            let line = "[\(timestamp)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
    }

    private enum Config {
        static let anthropicVersion = "2023-06-01"
        static let claudeRedactedThinkingBeta = "redact-thinking-2026-02-12"
        static let claudeVisibleThinkingBetas = [
            "claude-code-20250219",
            "oauth-2025-04-20",
            "interleaved-thinking-2025-05-14",
            "context-management-2025-06-27",
            "prompt-caching-scope-2026-01-05",
            "structured-outputs-2025-12-15",
            "fast-mode-2026-02-01",
            "token-efficient-tools-2026-03-28"
        ]
    }
    
    /**
     Starts the thinking proxy server on port 8317
     */
    func start() {
        guard !isRunning else {
            NSLog("[ThinkingProxy] Already running")
            return
        }
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            guard let port = NWEndpoint.Port(rawValue: proxyPort) else {
                NSLog("[ThinkingProxy] Invalid port: %d", proxyPort)
                return
            }
            listener = try NWListener(using: parameters, on: port)
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self?.isRunning = true
                    }
                    NSLog("[ThinkingProxy] Listening on port \(self?.proxyPort ?? 0)")
                case .failed(let error):
                    NSLog("[ThinkingProxy] Failed: \(error)")
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                case .cancelled:
                    NSLog("[ThinkingProxy] Cancelled")
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
            
        } catch {
            NSLog("[ThinkingProxy] Failed to start: \(error)")
        }
    }
    
    /**
     Stops the thinking proxy server
     */
    func stop() {
        stateQueue.sync {
            guard isRunning else { return }
            
            listener?.cancel()
            listener = nil
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
            NSLog("[ThinkingProxy] Stopped")
        }
    }
    
    /**
     Handles an incoming connection from a client
     */
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(from: connection)
    }
    
    /**
     Receives the HTTP request from the client
     Accumulates data until full request is received (handles large payloads)
     */
    private func receiveRequest(from connection: NWConnection, accumulatedData: Data = Data()) {
        // Start the iterative receive loop
        receiveNextChunk(from: connection, accumulatedData: accumulatedData)
    }
    
    /**
     Receives request data iteratively (uses async scheduling instead of recursion to avoid stack buildup)
     */
    private func receiveNextChunk(from connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive error: \(error)")
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            
            var newAccumulatedData = accumulatedData
            newAccumulatedData.append(data)
            
            // Find the end of headers (\r\n\r\n) using quick binary match to avoid O(N^2) UTF-8 string decodes on every chunk
            let headerEndPattern = Data([13, 10, 13, 10]) // "\r\n\r\n"
            if let headerEndRange = newAccumulatedData.range(of: headerEndPattern) {
                // Parse headers only, keeping the massive body as raw binary data
                let headerData = Data(newAccumulatedData[..<headerEndRange.upperBound])
                if let headerString = String(data: headerData, encoding: .utf8) {
                    
                    // Look for Content-Length
                    let lines = headerString.components(separatedBy: "\r\n")
                    if let contentLengthLine = lines.first(where: { $0.lowercased().starts(with: "content-length:") }) {
                        let parts = contentLengthLine.components(separatedBy: ":")
                        if parts.count >= 2 {
                            let contentLengthStr = parts[1].trimmingCharacters(in: .whitespaces)
                            if let contentLength = Int(contentLengthStr) {
                                let bodyStartIndex = headerEndRange.upperBound
                                let currentBodyLength = newAccumulatedData.count - bodyStartIndex
                                
                                // If we haven't received the full body yet, schedule next iteration
                                if currentBodyLength < contentLength {
                                    if isComplete {
                                        // End of stream but content length was not met; process the partial bytes we have
                                        self.processRequest(data: newAccumulatedData, connection: connection)
                                    } else {
                                        self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
                                    }
                                    return
                                }
                            }
                        }
                    }
                }
                
                // We have a complete request, process it
                self.processRequest(data: newAccumulatedData, connection: connection)
            } else if !isComplete {
                // Haven't found header end yet, schedule next iteration
                self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
            } else {
                // Complete but malformed (no headers end found), process what we have
                self.processRequest(data: newAccumulatedData, connection: connection)
            }
        }
    }
    
    /**
     Processes the HTTP request, modifies it if needed, and forwards to CLIProxyAPI
     */
    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendError(to: connection, statusCode: 400, message: "Invalid request")
            return
        }
        
        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(to: connection, statusCode: 400, message: "Invalid request line")
            return
        }
        
        // Extract method, path, and HTTP version
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            sendError(to: connection, statusCode: 400, message: "Invalid request format")
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        let httpVersion = parts[2]
        NSLog("[ThinkingProxy] Incoming request: \(method) \(path)")

        // Collect headers while preserving original casing
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        
        // Find the body start
        guard let bodyStartRange = requestString.range(of: "\r\n\r\n") else {
            NSLog("[ThinkingProxy] Error: Could not find body separator in request")
            sendError(to: connection, statusCode: 400, message: "Invalid request format - no body separator")
            return
        }
        
        let bodyStart = requestString.distance(from: requestString.startIndex, to: bodyStartRange.upperBound)
        let bodyString = String(requestString[requestString.index(requestString.startIndex, offsetBy: bodyStart)...])
        
        // Redirect Amp CLI login directly to ampcode.com to preserve auth state cookies
        if path.starts(with: "/auth/cli-login") || path.starts(with: "/api/auth/cli-login") {
            let loginPath = path.hasPrefix("/api/") ? String(path.dropFirst(4)) : path
            let redirectUrl = "https://ampcode.com" + loginPath
            NSLog("[ThinkingProxy] Redirecting Amp CLI login to: \(redirectUrl)")
            sendRedirect(to: connection, location: redirectUrl)
            return
        }

        // Rewrite Amp CLI paths
        var rewrittenPath = path
        if path.starts(with: "/provider/") {
            // Rewrite /provider/* to /api/provider/*
            rewrittenPath = "/api" + path
            NSLog("[ThinkingProxy] Rewriting Amp provider path: \(path) -> \(rewrittenPath)")
        }
        
        // Check if this is an Amp management request (anything not targeting provider or /v1)
        // Note: /provider/ paths are already rewritten to /api/provider/ above
        let isProviderPath = rewrittenPath.starts(with: "/api/provider/")
        let isCliProxyPath = rewrittenPath.starts(with: "/v1/") || rewrittenPath.starts(with: "/api/v1/")
        if !isProviderPath && !isCliProxyPath {
            let ampPath = rewrittenPath
            NSLog("[ThinkingProxy] Amp management request detected, forwarding to ampcode.com: \(ampPath)")
            forwardToAmp(method: method, path: ampPath, version: httpVersion, headers: headers, body: bodyString, originalConnection: connection)
            return
        }
        
        // Try to parse and modify JSON body for POST requests
        var modifiedBody = bodyString

        if method == "POST" && !bodyString.isEmpty {
            ThinkingProxy.fileLog("INCOMING REQUEST: \(method) \(rewrittenPath)")
            if let summary = summarizeReasoningFields(in: bodyString) {
                ThinkingProxy.fileLog("REQUEST REASONING: \(summary)")
            }
            if isCursorModel(modifiedBody) {
                guard BETA_FLAG else {
                    NSLog("[ThinkingProxy] Warning: Cursor model requested but Beta mode is disabled.")
                    sendError(to: connection, statusCode: 400, message: "Cursor provider is a beta feature. Please enable Beta mode in DroidProxy settings.")
                    return
                }
                guard isCursorEnabled() else {
                    NSLog("[ThinkingProxy] Warning: Cursor model requested but the provider is disabled in settings.")
                    sendError(to: connection, statusCode: 400, message: "Cursor provider is disabled in DroidProxy settings.")
                    return
                }
                forwardToCursor(method: method, path: rewrittenPath, version: httpVersion, headers: headers, body: modifiedBody, originalConnection: connection)
                return
            }
            if let result = processOpenAIFastMode(jsonString: modifiedBody, path: rewrittenPath) {
                modifiedBody = result
            }
        }

        // Rewrite /v1/responses to /v1/chat/completions for Gemini models since
        // CLIProxyAPIPlus does not support Gemini via the Responses API endpoint.
        if isResponsesAPIPath(rewrittenPath) && isGeminiModel(bodyString) {
            let newPath = rewrittenPath.replacingOccurrences(of: "/responses", with: "/chat/completions")
            NSLog("[ThinkingProxy] Rewriting Gemini responses path: \(rewrittenPath) -> \(newPath)")
            ThinkingProxy.fileLog("REWRITE PATH: \(rewrittenPath) -> \(newPath) (Gemini model)")
            rewrittenPath = newPath
        }

        let forwardHeaders = headersForForwarding(headers, bodyString: modifiedBody)
        forwardRequest(method: method, path: rewrittenPath, version: httpVersion, headers: forwardHeaders, body: modifiedBody, originalConnection: connection)
    }

    private func headersForForwarding(_ headers: [(String, String)], bodyString: String) -> [(String, String)] {
        guard shouldRequestVisibleClaudeThinking(bodyString: bodyString) else {
            return headers
        }

        ThinkingProxy.fileLog("CLAUDE visible thinking enabled: removing \(Config.claudeRedactedThinkingBeta) from Anthropic-Beta")
        return headersWithVisibleClaudeThinkingBetas(headers)
    }

    private func shouldRequestVisibleClaudeThinking(bodyString: String) -> Bool {
        guard let jsonData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String,
              isClaudeModel(model),
              let thinking = json["thinking"] as? [String: Any],
              let thinkingType = thinking["type"] as? String else {
            return false
        }

        switch thinkingType {
        case "enabled", "adaptive", "auto":
            return true
        default:
            return false
        }
    }

    private func isClaudeModel(_ model: String) -> Bool {
        model.starts(with: "claude-") || model.starts(with: "gemini-claude-")
    }

    private func headersWithVisibleClaudeThinkingBetas(_ headers: [(String, String)]) -> [(String, String)] {
        var forwardedHeaders: [(String, String)] = []
        var betaCandidates: [String] = []

        for (name, value) in headers {
            if name.caseInsensitiveCompare("anthropic-beta") == .orderedSame {
                betaCandidates.append(contentsOf: parseAnthropicBetas(value))
                continue
            }
            forwardedHeaders.append((name, value))
        }

        betaCandidates.append(contentsOf: Config.claudeVisibleThinkingBetas)

        var seen = Set<String>()
        let visibleBetas = betaCandidates.compactMap { rawBeta -> String? in
            let beta = rawBeta.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !beta.isEmpty else { return nil }
            let normalizedBeta = beta.lowercased()
            guard normalizedBeta != Config.claudeRedactedThinkingBeta else { return nil }
            guard !seen.contains(normalizedBeta) else { return nil }
            seen.insert(normalizedBeta)
            return beta
        }

        forwardedHeaders.append(("Anthropic-Beta", visibleBetas.joined(separator: ",")))
        return forwardedHeaders
    }

    private func parseAnthropicBetas(_ value: String) -> [String] {
        value.split(separator: ",").map { String($0) }
    }

    private static let responsesAPIPaths: Set<String> = [
        "/v1/responses",
        "/api/v1/responses"
    ]

    private func isResponsesAPIPath(_ path: String) -> Bool {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        return Self.responsesAPIPaths.contains(normalizedPath)
    }

    /// Extracts just the reasoning/thinking metadata from a request body so the log
    /// shows what Droid is actually sending without us also dumping the entire prompt.
    /// Returns nil only when the body can't be parsed.
    private func summarizeReasoningFields(in bodyString: String) -> String? {
        guard let data = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var parts: [String] = []
        if let model = json["model"] as? String {
            parts.append("model=\(model)")
        }
        let inspectedKeys = [
            "reasoning",
            "reasoning_effort",
            "thinking",
            "output_config",
            "service_tier",
            "generationConfig"
        ]
        for key in inspectedKeys {
            guard let value = json[key] else { continue }
            parts.append("\(key)=\(reasoningFieldDescription(value))")
        }
        if parts.count == 1 {
            parts.append("<no reasoning/thinking fields>")
        }
        return parts.joined(separator: " ")
    }

    private func reasoningFieldDescription(_ value: Any) -> String {
        if let dict = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        if let arr = value as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: arr),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        if let str = value as? String {
            return "\"\(str)\""
        }
        return "\(value)"
    }

    private func isGeminiModel(_ bodyString: String) -> Bool {
        guard let jsonData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String else {
            return false
        }
        return model.hasPrefix("gemini-")
    }

    // MARK: - Surgical JSON string helpers
    // These scan the top-level JSON object and modify specific fields in-place, preserving
    // the original JSON structure and key ordering. This is critical because
    // JSONSerialization.data() reorders keys alphabetically, which breaks Anthropic's
    // prompt cache matching.

    /// Injects a new JSON field after a given key's value in the JSON string.
    /// Only matches keys at the top-level request object so nested assistant content
    /// blocks remain unchanged.
    private func injectJSONField(in json: String, afterKey: String, fieldName: String, fieldValue: String) -> String {
        guard let location = findTopLevelFieldLocation(in: json, key: afterKey) else {
            NSLog("[ThinkingProxy] Warning: Could not find key '\(afterKey)' for field injection")
            return json
        }

        var result = json
        result.insert(contentsOf: ",\"\(fieldName)\":\(fieldValue)", at: location.pairRange.upperBound)
        return result
    }

    private struct TopLevelFieldLocation {
        let pairRange: Range<String.Index>
        let valueRange: Range<String.Index>
    }

    private func findTopLevelFieldLocation(in json: String, key targetKey: String) -> TopLevelFieldLocation? {
        guard var index = firstNonWhitespaceIndex(in: json, from: json.startIndex),
              json[index] == "{" else {
            return nil
        }

        index = json.index(after: index)

        while true {
            guard let keyStart = firstNonWhitespaceIndex(in: json, from: index) else {
                return nil
            }

            let token = json[keyStart]
            if token == "}" {
                return nil
            }
            guard token == "\"" else {
                return nil
            }

            guard let (key, keyEnd) = parseJSONStringToken(in: json, startingAt: keyStart),
                  let colonIndex = firstNonWhitespaceIndex(in: json, from: keyEnd),
                  json[colonIndex] == ":" else {
                return nil
            }

            let afterColon = json.index(after: colonIndex)
            guard let valueStart = firstNonWhitespaceIndex(in: json, from: afterColon),
                  let valueEnd = consumeJSONValue(in: json, startingAt: valueStart) else {
                return nil
            }

            if key == targetKey {
                return TopLevelFieldLocation(pairRange: keyStart..<valueEnd,
                                             valueRange: valueStart..<valueEnd)
            }

            guard let delimiterIndex = firstNonWhitespaceIndex(in: json, from: valueEnd) else {
                return nil
            }

            let delimiter = json[delimiterIndex]
            if delimiter == "," {
                index = json.index(after: delimiterIndex)
                continue
            }
            if delimiter == "}" {
                return nil
            }
            return nil
        }
    }

    private func firstNonWhitespaceIndex(in json: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < json.endIndex, json[index].isWhitespace {
            index = json.index(after: index)
        }
        return index < json.endIndex ? index : nil
    }

    private func parseJSONStringToken(in json: String, startingAt startQuote: String.Index) -> (String, String.Index)? {
        guard json[startQuote] == "\"" else {
            return nil
        }

        var index = json.index(after: startQuote)
        var escaped = false

        while index < json.endIndex {
            let char = json[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                let value = String(json[json.index(after: startQuote)..<index])
                return (value, json.index(after: index))
            }
            index = json.index(after: index)
        }

        return nil
    }

    private func consumeJSONValue(in json: String, startingAt start: String.Index) -> String.Index? {
        guard start < json.endIndex else {
            return nil
        }

        let first = json[start]
        if first == "\"" {
            return parseJSONStringToken(in: json, startingAt: start)?.1
        }

        if first == "{" || first == "[" {
            return consumeCompositeJSONValue(in: json, startingAt: start)
        }

        var index = start
        while index < json.endIndex {
            let char = json[index]
            if char == "," || char == "}" || char == "]" || char.isWhitespace {
                break
            }
            index = json.index(after: index)
        }

        return index > start ? index : nil
    }

    private func consumeCompositeJSONValue(in json: String, startingAt start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false

        while index < json.endIndex {
            let char = json[index]

            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" || char == "[" {
                    depth += 1
                } else if char == "}" || char == "]" {
                    depth -= 1
                    if depth == 0 {
                        return json.index(after: index)
                    }
                    if depth < 0 {
                        return nil
                    }
                }
            }

            index = json.index(after: index)
        }

        return nil
    }

    private static let fastTierEligibleResponsePaths: Set<String> = [
        "/v1/responses",
        "/api/v1/responses"
    ]

    private static let ampProviderToolRewritePattern = "\"name\"\\s*:\\s*\"bash\""
    private static let ampProviderRewriteCarryLength = 31

    private final class AmpProviderRewriteState {
        var carry = ""
    }

    private func shouldNormalizeAmpProviderResponse(for path: String) -> Bool {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        return normalizedPath.starts(with: "/api/provider/")
    }

    private func normalizeAmpProviderResponseChunk(_ data: Data,
                                                   rewriteState: AmpProviderRewriteState,
                                                   isComplete: Bool) -> Data {
        let carryPrefix = rewriteState.carry
        rewriteState.carry = ""

        guard let chunk = String(data: data, encoding: .utf8) else {
            if carryPrefix.isEmpty {
                return data
            }
            var passthrough = Data(carryPrefix.utf8)
            passthrough.append(data)
            return passthrough
        }

        var combined = carryPrefix + chunk
        let beforeRewrite = combined
        combined = combined.replacingOccurrences(of: Self.ampProviderToolRewritePattern,
                                                 with: "\"name\":\"Bash\"",
                                                 options: .regularExpression)
        if combined != beforeRewrite {
            NSLog("[ThinkingProxy] Normalized Amp provider tool name(s) in response chunk")
        }

        guard !isComplete else {
            return Data(combined.utf8)
        }

        let carryLength = min(Self.ampProviderRewriteCarryLength, combined.count)
        if carryLength == combined.count {
            rewriteState.carry = combined
            return Data()
        }

        let carryStart = combined.index(combined.endIndex, offsetBy: -carryLength)
        let output = String(combined[..<carryStart])
        rewriteState.carry = String(combined[carryStart...])
        return Data(output.utf8)
    }

    private func flushNormalizedResponseCarry(_ rewriteState: AmpProviderRewriteState?) -> Data? {
        guard let rewriteState, !rewriteState.carry.isEmpty else {
            return nil
        }
        let carry = rewriteState.carry
        rewriteState.carry = ""
        return Data(carry.utf8)
    }

    private func processOpenAIFastMode(jsonString: String, path: String) -> String? {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        guard Self.fastTierEligibleResponsePaths.contains(normalizedPath) else { return nil }

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String else {
            return nil
        }

        switch model {
        case "gpt-5.2":
            guard AppPreferences.gpt52FastMode else { return nil }
        case "gpt-5.4":
            guard AppPreferences.gpt54FastMode else { return nil }
        case "gpt-5.5":
            guard AppPreferences.gpt55FastMode else { return nil }
        case "gpt-5.3-codex":
            guard AppPreferences.gpt53CodexFastMode else { return nil }
        default:
            return nil
        }

        guard json["service_tier"] == nil else { return nil }

        let result = injectJSONField(in: jsonString, afterKey: "model", fieldName: "service_tier",
                                     fieldValue: "\"priority\"")
        NSLog("[ThinkingProxy] Injected service_tier=priority for model '\(model)' on path \(path)")
        ThinkingProxy.fileLog("INJECTED service_tier=priority for model \(model)")
        return result
    }

    /**
     Forwards Amp API requests to ampcode.com, stripping the /api/ prefix
     */
    private func forwardToAmp(method: String, path: String, version: String, headers: [(String, String)], body: String, originalConnection: NWConnection) {
        // Create TLS parameters for HTTPS
        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        
        // Create connection to ampcode.com:443
        let endpoint = NWEndpoint.hostPort(host: "ampcode.com", port: 443)
        let targetConnection = NWConnection(to: endpoint, using: parameters)
        
        targetConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Build the forwarded request
                var forwardedRequest = "\(method) \(path) \(version)\r\n"
                
                // Forward most headers, excluding some that need to be overridden
                let excludedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]
                for (name, value) in headers {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
                }
                
                // Override Host header for ampcode.com
                forwardedRequest += "Host: ampcode.com\r\n"
                forwardedRequest += "Connection: close\r\n"
                
                let contentLength = body.utf8.count
                forwardedRequest += "Content-Length: \(contentLength)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body
                
                // Send to ampcode.com
                if let requestData = forwardedRequest.data(using: .utf8) {
                    targetConnection.send(content: requestData, completion: .contentProcessed({ error in
                        if let error = error {
                            NSLog("[ThinkingProxy] Send error to ampcode.com: \(error)")
                            targetConnection.cancel()
                            originalConnection.cancel()
                        } else {
                            // Receive response from ampcode.com and rewrite Location headers
                            self.receiveAmpResponse(from: targetConnection, originalConnection: originalConnection)
                        }
                    }))
                }
                
            case .failed(let error):
                NSLog("[ThinkingProxy] Connection to ampcode.com failed: \(error)")
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Could not connect to ampcode.com")
                targetConnection.cancel()
                
            default:
                break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    
    /**
     Receives response from ampcode.com and rewrites Location headers to add /api/ prefix
     */
    private func receiveAmpResponse(from targetConnection: NWConnection, originalConnection: NWConnection) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive Amp response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                // Convert to string to rewrite headers
                if var responseString = String(data: data, encoding: .utf8) {
                    // Rewrite Location headers to prepend /api/
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nlocation: /",
                        with: "\r\nlocation: /api/",
                        options: .caseInsensitive
                    )
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nLocation: /",
                        with: "\r\nLocation: /api/"
                    )

                    // Rewrite absolute Location headers to keep browser on localhost proxy
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nLocation: https://ampcode.com/",
                        with: "\r\nLocation: /api/",
                        options: .caseInsensitive
                    )
                    responseString = responseString.replacingOccurrences(
                        of: "\r\nLocation: http://ampcode.com/",
                        with: "\r\nLocation: /api/",
                        options: .caseInsensitive
                    )

                    // Rewrite cookie domain so browser accepts cookies from localhost
                    responseString = responseString.replacingOccurrences(
                        of: "Domain=.ampcode.com",
                        with: "Domain=localhost",
                        options: .caseInsensitive
                    )
                    responseString = responseString.replacingOccurrences(
                        of: "Domain=ampcode.com",
                        with: "Domain=localhost",
                        options: .caseInsensitive
                    )
                    
                    if let modifiedData = responseString.data(using: .utf8) {
                        originalConnection.send(content: modifiedData, completion: .contentProcessed({ sendError in
                            if let sendError = sendError {
                                NSLog("[ThinkingProxy] Send Amp response error: \(sendError)")
                            }
                            
                            if isComplete {
                                targetConnection.cancel()
                                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                                    originalConnection.cancel()
                                }))
                            } else {
                                // Continue receiving more data
                                self.receiveAmpResponse(from: targetConnection, originalConnection: originalConnection)
                            }
                        }))
                    }
                } else {
                    // Not UTF-8, forward as-is
                    originalConnection.send(content: data, completion: .contentProcessed({ sendError in
                        if let sendError = sendError {
                            NSLog("[ThinkingProxy] Send Amp response error: \(sendError)")
                        }
                        
                        if isComplete {
                            targetConnection.cancel()
                            originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                                originalConnection.cancel()
                            }))
                        } else {
                            self.receiveAmpResponse(from: targetConnection, originalConnection: originalConnection)
                        }
                    }))
                }
            } else if isComplete {
                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    originalConnection.cancel()
                }))
            }
        }
    }

    /**
     Forwards the request to CLIProxyAPI on port 8318 (pass-through for non-thinking requests)
     */
    private func forwardRequest(method: String, path: String, version: String, headers: [(String, String)], body: String, originalConnection: NWConnection) {
        // Create connection to CLIProxyAPI
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            NSLog("[ThinkingProxy] Invalid target port: %d", targetPort)
            sendError(to: originalConnection, statusCode: 500, message: "Internal Server Error")
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: port)
        let parameters = NWParameters.tcp
        let targetConnection = NWConnection(to: endpoint, using: parameters)
        
        targetConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Build the forwarded request
                var forwardedRequest = "\(method) \(path) \(version)\r\n"
                let excludedHeaders: Set<String> = ["content-length", "host", "transfer-encoding"]

                for (name, value) in headers {
                    let lowercasedName = name.lowercased()
                    if excludedHeaders.contains(lowercasedName) {
                        continue
                    }
                    forwardedRequest += "\(name): \(value)\r\n"
                }

                // Override Host header
                forwardedRequest += "Host: \(self.targetHost):\(self.targetPort)\r\n"
                // Always close connections - this proxy doesn't support keep-alive/pipelining
                forwardedRequest += "Connection: close\r\n"
                
                let contentLength = body.utf8.count
                forwardedRequest += "Content-Length: \(contentLength)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body
                
                // Send to CLIProxyAPI
                if let requestData = forwardedRequest.data(using: .utf8) {
                    targetConnection.send(content: requestData, completion: .contentProcessed({ error in
                        if let error = error {
                            NSLog("[ThinkingProxy] Send error: \(error)")
                            targetConnection.cancel()
                            originalConnection.cancel()
                        } else {
                            let normalizeAmpProviderResponse = self.shouldNormalizeAmpProviderResponse(for: path)
                            self.receiveResponse(from: targetConnection,
                                                 originalConnection: originalConnection,
                                                 normalizeAmpProviderResponse: normalizeAmpProviderResponse)
                        }
                    }))
                }
                
            case .failed(let error):
                NSLog("[ThinkingProxy] Target connection failed: \(error)")
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway")
                targetConnection.cancel()
                
            default:
                break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    /**
     Receives response from CLIProxyAPI
     Starts the streaming loop for response data
     */
    private func receiveResponse(from targetConnection: NWConnection,
                                 originalConnection: NWConnection,
                                 normalizeAmpProviderResponse: Bool = false) {
        let rewriteState = normalizeAmpProviderResponse ? AmpProviderRewriteState() : nil
        // Start the streaming loop
        streamNextChunk(from: targetConnection, to: originalConnection, rewriteState: rewriteState)
    }
    
    /**
     Streams response chunks iteratively (uses async scheduling instead of recursion to avoid stack buildup)
     */
    private func streamNextChunk(from targetConnection: NWConnection,
                                 to originalConnection: NWConnection,
                                 rewriteState: AmpProviderRewriteState? = nil) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                var outboundData = data
                if let rewriteState {
                    outboundData = self.normalizeAmpProviderResponseChunk(data, rewriteState: rewriteState, isComplete: isComplete)
                }

                if outboundData.isEmpty && !isComplete {
                    self.streamNextChunk(from: targetConnection, to: originalConnection, rewriteState: rewriteState)
                    return
                }

                // Forward response chunk to original client
                originalConnection.send(content: outboundData, completion: .contentProcessed({ sendError in
                    if let sendError = sendError {
                        NSLog("[ThinkingProxy] Send response error: \(sendError)")
                    }
                    
                    if isComplete {
                        targetConnection.cancel()
                        // Always close client connection - no keep-alive/pipelining support
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                            originalConnection.cancel()
                        }))
                    } else {
                        // Schedule next iteration of the streaming loop
                        self.streamNextChunk(from: targetConnection, to: originalConnection, rewriteState: rewriteState)
                    }
                }))
            } else if isComplete {
                targetConnection.cancel()
                if let carryData = self.flushNormalizedResponseCarry(rewriteState), !carryData.isEmpty {
                    originalConnection.send(content: carryData, completion: .contentProcessed({ _ in
                        // Always close client connection - no keep-alive/pipelining support
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                            originalConnection.cancel()
                        }))
                    }))
                } else {
                    // Always close client connection - no keep-alive/pipelining support
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                        originalConnection.cancel()
                    }))
                }
            }
        }
    }
    
    /**
     Sends an error response to the client
     */
    private func sendError(to connection: NWConnection, statusCode: Int, message: String) {
        // Build response with proper CRLF line endings and correct byte count
        guard let bodyData = message.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        let headers = "HTTP/1.1 \(statusCode) \(message)\r\n" +
                     "Content-Type: text/plain\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"
        
        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        var responseData = Data()
        responseData.append(headerData)
        responseData.append(bodyData)
        
        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendRedirect(to connection: NWConnection, location: String) {
        let headers = "HTTP/1.1 302 Found\r\n" +
                     "Location: \(location)\r\n" +
                     "Content-Length: 0\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"

        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: headerData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    // MARK: - Cursor API Proxying
    
    private func isCursorModel(_ bodyString: String) -> Bool {
        guard let jsonData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String else {
            return false
        }
        return model.hasPrefix("cursor-")
    }

    private func isCursorEnabled() -> Bool {
        if let saved = UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] {
            return saved["cursor"] ?? true
        }
        return true
    }

    private func loadCursorApiKey() -> String? {
        let authDir = AuthPaths.authDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: authDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type.lowercased() == "cursor",
                  let apiKey = json["apiKey"] as? String,
                  !(json["disabled"] as? Bool ?? false) else {
                continue
            }
            return apiKey
        }
        return nil
    }

    private func forwardToCursor(method: String, path: String, version: String, headers: [(String, String)], body: String, originalConnection: NWConnection) {
        guard let apiKey = loadCursorApiKey() else {
            NSLog("[ThinkingProxy] Error: No active Cursor API key found")
            sendError(to: originalConnection, statusCode: 401, message: "No active Cursor API key found. Please add a Cursor key in DroidProxy settings.")
            return
        }
        
        let tlsOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        
        let endpoint = NWEndpoint.hostPort(host: "cursor-api.standardagents.ai", port: 443)
        let targetConnection = NWConnection(to: endpoint, using: parameters)
        
        targetConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                var forwardedRequest = "\(method) \(path) \(version)\r\n"
                let excludedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "authorization"]
                for (name, value) in headers {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
                }
                
                forwardedRequest += "Host: cursor-api.standardagents.ai\r\n"
                forwardedRequest += "Authorization: Bearer \(apiKey)\r\n"
                forwardedRequest += "Connection: close\r\n"
                forwardedRequest += "Content-Length: \(body.utf8.count)\r\n\r\n"
                forwardedRequest += body
                
                if let requestData = forwardedRequest.data(using: .utf8) {
                    targetConnection.send(content: requestData, completion: .contentProcessed({ error in
                        if let error = error {
                            NSLog("[ThinkingProxy] Send error to cursor-api.standardagents.ai: \(error)")
                            targetConnection.cancel()
                            originalConnection.cancel()
                        } else {
                            self.receiveCursorResponse(from: targetConnection, originalConnection: originalConnection)
                        }
                    }))
                }
                
            case .failed(let error):
                NSLog("[ThinkingProxy] Connection to cursor-api.standardagents.ai failed: \(error)")
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Could not connect to cursor-api.standardagents.ai")
                targetConnection.cancel()
                
            default:
                break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }

    private func receiveCursorResponse(from targetConnection: NWConnection, originalConnection: NWConnection) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive Cursor response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                originalConnection.send(content: data, completion: .contentProcessed({ sendError in
                    if let sendError = sendError {
                        NSLog("[ThinkingProxy] Send Cursor response error: \(sendError)")
                    }
                    
                    if isComplete {
                        targetConnection.cancel()
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                            originalConnection.cancel()
                        }))
                    } else {
                        self.receiveCursorResponse(from: targetConnection, originalConnection: originalConnection)
                    }
                }))
            } else if isComplete {
                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    originalConnection.cancel()
                }))
            }
        }
    }
}
