import Foundation
import Network

/**
 A lightweight HTTP proxy that injects reasoning settings for supported Claude and Codex GPT models.

 Current behavior:
 - Requests whose `model` contains `opus-4-7` receive `thinking: {"type":"adaptive","display":"summarized"}`
   plus `output_config.effort` from `AppPreferences.opus47ThinkingEffort`
 - Requests whose `model` contains `opus-4-6` receive `thinking: {"type":"adaptive"}`
   plus `output_config.effort` from `AppPreferences.opus46ThinkingEffort`
 - Requests whose `model` contains `opus-4-5` receive classic
   `thinking: {"type":"enabled","budget_tokens":N}` mapped from
   `AppPreferences.opus45ThinkingEffort` (Opus 4.5 does not support adaptive thinking).
 - Requests whose `model` contains `sonnet-4-6` receive `thinking: {"type":"adaptive"}`
   plus `output_config.effort` from `AppPreferences.sonnet46ThinkingEffort`
 - Claude requests with thinking enabled forward an Anthropic-Beta header that omits
   `redact-thinking-2026-02-12`, otherwise Claude emits only signed empty thinking blocks.
 - Requests whose `model` is exactly `gpt-5.3-codex` receive `reasoning: {"effort":"..."}`
   from `AppPreferences.gpt53CodexReasoningEffort`
- Requests whose `model` is exactly `gpt-5.2`, `gpt-5.4`, or `gpt-5.5` receive
  `reasoning: {"effort":"..."}` from `AppPreferences.gpt52ReasoningEffort`,
  `AppPreferences.gpt54ReasoningEffort`, or `AppPreferences.gpt55ReasoningEffort`
- Other models are forwarded unchanged
- Requests whose `model` is exactly `kimi-k2.6` receive `reasoning: {"effort":"..."}`
  from `AppPreferences.k26ReasoningEffort`

The proxy edits the raw JSON string instead of re-serializing it so cache-sensitive key
ordering is preserved.
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
    static func fileLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        logQueue.async {
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
            
            // Check if we have a complete HTTP request
            if let requestString = String(data: newAccumulatedData, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                
                // Extract Content-Length if present
                let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
                let headerPart = String(requestString.prefix(headerEndIndex))
                
                if let contentLengthLine = headerPart.components(separatedBy: "\r\n").first(where: { $0.lowercased().starts(with: "content-length:") }) {
                    let contentLengthStr = contentLengthLine.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                    if let contentLength = Int(contentLengthStr) {
                        let bodyStartIndex = headerEndIndex
                        let currentBodyLength = newAccumulatedData.count - bodyStartIndex
                        
                        // If we haven't received the full body yet, schedule next iteration
                        if currentBodyLength < contentLength {
                            self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
                            return
                        }
                    }
                }
                
                // We have a complete request, process it
                self.processRequest(data: newAccumulatedData, connection: connection)
            } else if !isComplete {
                // Haven't found header end yet, schedule next iteration
                self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
            } else {
                // Complete but malformed, process what we have
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
            ThinkingProxy.fileLog("ORIGINAL BODY (first 500): \(String(bodyString.prefix(500)))")
            if let transformed = processThinkingParameter(jsonString: bodyString) {
                modifiedBody = transformed
                ThinkingProxy.fileLog("MODIFIED BODY (first 500): \(String(modifiedBody.prefix(500)))")
                ThinkingProxy.fileLog("THINKING INJECTED: true")
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

    /**
     Processes the JSON body to add thinking or reasoning parameters for supported models.
     Uses surgical string operations to preserve original JSON structure and key ordering,
     which is critical for Anthropic's prompt caching (cache_control fields must be preserved).
     Returns tuple of (modifiedJSON, needsTransformation)
     */
    private func processThinkingParameter(jsonString: String) -> String? {
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String else {
            return nil
        }

        if let variant = DroidProxyModelCatalog.advancedVariant(for: model) {
            return processAdvancedModelVariant(jsonString: jsonString, json: json, requestedModel: model, variant: variant)
        }

        if let effort = codexReasoningEffort(for: model) {
            var result = jsonString
            result = injectJSONField(in: result, afterKey: "model", fieldName: "reasoning",
                                     fieldValue: "{\"effort\":\"\(effort)\"}")
            NSLog("[ThinkingProxy] Injected Codex reasoning for '\(model)' with effort '\(effort)'")
            ThinkingProxy.fileLog("INJECTED Codex reasoning: effort=\(effort) for model \(model)")
            return result
        }

        if let effort = kimiReasoningEffort(for: model) {
            var result = jsonString
            result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "reasoning_effort",
                                              fieldValue: "\"\(effort)\"",
                                              existsInJSON: json["reasoning_effort"] != nil)
            NSLog("[ThinkingProxy] Injected Kimi reasoning_effort for '\(model)' with effort '\(effort)'")
            ThinkingProxy.fileLog("INJECTED Kimi reasoning_effort=\(effort) for model \(model)")
            return result
        }

        if let level = geminiThinkingLevel(for: model) {
            var result = jsonString
            result = injectGeminiThinkingLevel(in: result, level: level, generationConfigExists: json["generationConfig"] != nil)
            NSLog("[ThinkingProxy] Injected Gemini thinking for '\(model)' with level '\(level)'")
            ThinkingProxy.fileLog("INJECTED Gemini thinking: level=\(level) for model \(model)")
            return result
        }

        // Opus 4.5 uses classic extended thinking (budget_tokens) — it does not support adaptive.
        if isOpus45Model(model) {
            return processOpus45ClassicThinking(jsonString: jsonString, json: json, model: model)
        }

        guard let effort = claudeAdaptiveThinkingEffort(for: model) else {
            return nil
        }

        return processClaudeAdaptiveThinking(jsonString: jsonString, json: json, model: model, effort: effort, allowMaxBudgetMode: true)
    }

    private func processAdvancedModelVariant(jsonString: String, json: [String: Any], requestedModel: String, variant: DroidProxyModelVariant) -> String? {
        let baseModel = variant.definition.baseModel
        let level = variant.level.value
        let rewrittenJSON = rewriteModelValue(in: jsonString, from: requestedModel, to: baseModel)

        switch variant.definition.kind {
        case .codex:
            var result = rewrittenJSON
            result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "reasoning",
                                              fieldValue: "{\"effort\":\"\(level)\"}",
                                              existsInJSON: json["reasoning"] != nil)
            NSLog("[ThinkingProxy] Injected advanced Codex reasoning for '\(requestedModel)' as '\(baseModel)' with effort '\(level)'")
            ThinkingProxy.fileLog("INJECTED advanced Codex reasoning: effort=\(level) for model \(requestedModel) -> \(baseModel)")
            return result

        case .kimi:
            var result = rewrittenJSON
            result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "reasoning_effort",
                                              fieldValue: "\"\(level)\"",
                                              existsInJSON: json["reasoning_effort"] != nil)
            NSLog("[ThinkingProxy] Injected advanced Kimi reasoning_effort for '\(requestedModel)' as '\(baseModel)' with effort '\(level)'")
            ThinkingProxy.fileLog("INJECTED advanced Kimi reasoning_effort=\(level) for model \(requestedModel) -> \(baseModel)")
            return result

        case .gemini:
            var result = rewrittenJSON
            result = injectGeminiThinkingLevel(in: result, level: level, generationConfigExists: json["generationConfig"] != nil)
            NSLog("[ThinkingProxy] Injected advanced Gemini thinking for '\(requestedModel)' as '\(baseModel)' with level '\(level)'")
            ThinkingProxy.fileLog("INJECTED advanced Gemini thinking: level=\(level) for model \(requestedModel) -> \(baseModel)")
            return result

        case .claudeClassic:
            return processOpus45ClassicThinking(jsonString: rewrittenJSON, json: json, model: baseModel, effort: level)

        case .claudeAdaptive:
            return processClaudeAdaptiveThinking(jsonString: rewrittenJSON, json: json, model: baseModel, effort: level, allowMaxBudgetMode: false)
        }
    }

    private func processClaudeAdaptiveThinking(jsonString: String, json: [String: Any], model: String, effort: String, allowMaxBudgetMode: Bool) -> String {
        var result = jsonString

        result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "stream",
                                          fieldValue: "true", existsInJSON: json["stream"] != nil)

        if allowMaxBudgetMode && AppPreferences.claudeMaxBudgetMode &&
            (model.contains("sonnet-4-6") || model.contains("opus-4-6")) {
            // Sonnet 4.6 / Opus 4.6 classic extended-thinking override. budget_tokens must be strictly less
            // than max_tokens (min 1024). Request body changes stay inside the adaptive-thinking
            // window this path already controls.
            let maxTokens = 64000
            let budgetTokens = maxTokens - 1
            result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "max_tokens",
                                              fieldValue: "\(maxTokens)",
                                              existsInJSON: json["max_tokens"] != nil)
            result = replaceOrInjectJSONField(in: result, afterKey: "max_tokens",
                                              fieldName: "thinking",
                                              fieldValue: "{\"type\":\"enabled\",\"budget_tokens\":\(budgetTokens)}",
                                              existsInJSON: json["thinking"] != nil)
            result = replaceOrInjectJSONField(in: result, afterKey: "thinking", fieldName: "output_config",
                                              fieldValue: "{\"effort\":\"max\"}",
                                              existsInJSON: json["output_config"] != nil)
            NSLog("[ThinkingProxy] Injected classic budget_tokens max mode for '\(model)' budget=\(budgetTokens) max_tokens=\(maxTokens)")
            ThinkingProxy.fileLog("INJECTED classic budget_tokens max mode: budget_tokens=\(budgetTokens) max_tokens=\(maxTokens) for model \(model)")
        } else {
            let thinkingValue = isOpus47Model(model)
                ? "{\"type\":\"adaptive\",\"display\":\"summarized\"}"
                : "{\"type\":\"adaptive\"}"
            result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "thinking",
                                              fieldValue: thinkingValue,
                                              existsInJSON: json["thinking"] != nil)
            result = replaceOrInjectJSONField(in: result, afterKey: "thinking", fieldName: "output_config",
                                              fieldValue: "{\"effort\":\"\(effort)\"}",
                                              existsInJSON: json["output_config"] != nil)
            NSLog("[ThinkingProxy] Injected adaptive thinking for '\(model)' with effort '\(effort)'")
            ThinkingProxy.fileLog("INJECTED adaptive thinking: effort=\(effort) for model \(model)")
        }

        return result
    }

    private func codexReasoningEffort(for model: String) -> String? {
        switch model {
        case "gpt-5.2":
            return AppPreferences.gpt52ReasoningEffort
        case "gpt-5.3-codex":
            return AppPreferences.gpt53CodexReasoningEffort
        case "gpt-5.4":
            return AppPreferences.gpt54ReasoningEffort
        case "gpt-5.5":
            return AppPreferences.gpt55ReasoningEffort
        default:
            return nil
        }
    }

    private func kimiReasoningEffort(for model: String) -> String? {
        if model == "kimi-k2.6" {
            return AppPreferences.k26ReasoningEnabled ? "high" : nil
        }
        return nil
    }

    /// Replaces an existing JSON field's value or injects it if missing.
    private func replaceOrInjectJSONField(in json: String, afterKey: String, fieldName: String, fieldValue: String, existsInJSON: Bool) -> String {
        if existsInJSON {
            return replaceJSONFieldValue(in: json, fieldName: fieldName, newValue: fieldValue)
        }
        return injectJSONField(in: json, afterKey: afterKey, fieldName: fieldName, fieldValue: fieldValue)
    }

    private func injectGeminiThinkingLevel(in json: String, level: String, generationConfigExists: Bool) -> String {
        let generationConfigValue = "{\"thinkingConfig\":{\"thinking_level\":\"\(level)\"}}"
        guard generationConfigExists else {
            return injectJSONField(in: json, afterKey: "model", fieldName: "generationConfig", fieldValue: generationConfigValue)
        }

        guard let generationConfigLocation = findTopLevelFieldLocation(in: json, key: "generationConfig") else {
            NSLog("[ThinkingProxy] Warning: Could not find generationConfig for Gemini thinking merge")
            return json
        }

        let generationConfig = String(json[generationConfigLocation.valueRange])
        guard let updatedGenerationConfig = upsertGeminiThinkingLevel(inGenerationConfig: generationConfig, level: level) else {
            return replaceJSONFieldValue(in: json, fieldName: "generationConfig", newValue: generationConfigValue)
        }

        var result = json
        result.replaceSubrange(generationConfigLocation.valueRange, with: updatedGenerationConfig)
        return result
    }

    private func upsertGeminiThinkingLevel(inGenerationConfig generationConfig: String, level: String) -> String? {
        let thinkingConfigValue = "{\"thinking_level\":\"\(level)\"}"
        guard let thinkingConfigLocation = findTopLevelFieldLocation(in: generationConfig, key: "thinkingConfig") else {
            return upsertJSONField(inObject: generationConfig, fieldName: "thinkingConfig", fieldValue: thinkingConfigValue)
        }

        let thinkingConfig = String(generationConfig[thinkingConfigLocation.valueRange])
        let updatedThinkingConfig = upsertJSONField(inObject: thinkingConfig,
                                                    fieldName: "thinking_level",
                                                    fieldValue: "\"\(level)\"") ?? thinkingConfigValue

        var result = generationConfig
        result.replaceSubrange(thinkingConfigLocation.valueRange, with: updatedThinkingConfig)
        return result
    }

    private func upsertJSONField(inObject object: String, fieldName: String, fieldValue: String) -> String? {
        guard let objectStart = firstNonWhitespaceIndex(in: object, from: object.startIndex),
              object[objectStart] == "{",
              let objectEnd = lastNonWhitespaceIndex(in: object),
              object[objectEnd] == "}" else {
            return nil
        }

        if let location = findTopLevelFieldLocation(in: object, key: fieldName) {
            var result = object
            result.replaceSubrange(location.valueRange, with: fieldValue)
            return result
        }

        var result = object
        let contentStart = object.index(after: objectStart)
        let isEmptyObject = firstNonWhitespaceIndex(in: object, from: contentStart) == objectEnd
        result.insert(contentsOf: "\(isEmptyObject ? "" : ",")\"\(fieldName)\":\(fieldValue)", at: objectEnd)
        return result
    }

    /// Replaces the value of an existing top-level JSON field.
    private func replaceJSONFieldValue(in json: String, fieldName: String, newValue: String) -> String {
        guard let location = findTopLevelFieldLocation(in: json, key: fieldName) else {
            NSLog("[ThinkingProxy] Warning: Could not find key '\(fieldName)' for value replacement")
            return json
        }

        var result = json
        result.replaceSubrange(location.valueRange, with: newValue)
        return result
    }

    private func claudeAdaptiveThinkingEffort(for model: String) -> String? {
        guard model.starts(with: "claude-") || model.starts(with: "gemini-claude-") else {
            return nil
        }

        if model.contains("opus-4-7") {
            return AppPreferences.opus47ThinkingEffort
        }
        if model.contains("opus-4-6") {
            return AppPreferences.opus46ThinkingEffort
        }
        if model.contains("sonnet-4-6") {
            return AppPreferences.sonnet46ThinkingEffort
        }
        return nil
    }

    private func isOpus47Model(_ model: String) -> Bool {
        model.contains("opus-4-7")
    }

    /// Matches Opus 4.5 (`claude-opus-4-5`, `gemini-claude-opus-4-5`, date-suffixed variants)
    /// without also matching Opus 4.5x variants like `opus-4-50` or `opus-4-5x`.
    /// The `opus-4-5` token must be at the end of the string or followed by a `-` delimiter.
    private func isOpus45Model(_ model: String) -> Bool {
        guard model.starts(with: "claude-") || model.starts(with: "gemini-claude-") else {
            return false
        }
        guard let range = model.range(of: "opus-4-5") else {
            return false
        }
        let suffix = model[range.upperBound...]
        return suffix.isEmpty || suffix.hasPrefix("-")
    }

    /// Opus 4.5 does not accept adaptive thinking. It requires the legacy
    /// `thinking: {type: "enabled", budget_tokens: N}` shape, where
    /// `budget_tokens < max_tokens` (min 1024).
    private func processOpus45ClassicThinking(jsonString: String, json: [String: Any], model: String, effort: String = AppPreferences.opus45ThinkingEffort) -> String? {
        let (budgetTokens, maxTokens) = opus45ClassicBudget(for: effort)

        var result = jsonString

        result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "stream",
                                          fieldValue: "true", existsInJSON: json["stream"] != nil)
        result = replaceOrInjectJSONField(in: result, afterKey: "model", fieldName: "max_tokens",
                                          fieldValue: "\(maxTokens)",
                                          existsInJSON: json["max_tokens"] != nil)
        result = replaceOrInjectJSONField(in: result, afterKey: "max_tokens",
                                          fieldName: "thinking",
                                          fieldValue: "{\"type\":\"enabled\",\"budget_tokens\":\(budgetTokens)}",
                                          existsInJSON: json["thinking"] != nil)

        NSLog("[ThinkingProxy] Injected Opus 4.5 classic thinking for '\(model)' effort=\(effort) budget_tokens=\(budgetTokens) max_tokens=\(maxTokens)")
        ThinkingProxy.fileLog("INJECTED Opus 4.5 classic thinking: effort=\(effort) budget_tokens=\(budgetTokens) max_tokens=\(maxTokens) for model \(model)")
        return result
    }

    /// Maps effort levels to (budget_tokens, max_tokens) pairs for Opus 4.5.
    /// Opus 4.5 supports `max_tokens` up to 64000 and requires budget_tokens < max_tokens.
    private func opus45ClassicBudget(for effort: String) -> (Int, Int) {
        switch effort {
        case "low":
            return (4000, 16000)
        case "medium":
            return (16000, 32000)
        case "high":
            return (32000, 48000)
        case "max":
            return (48000, 64000)
        default:
            return (32000, 48000)
        }
    }

    private func geminiThinkingLevel(for model: String) -> String? {
        switch model {
        case "gemini-3.1-pro-preview":
            return AppPreferences.gemini31ProThinkingLevel
        case "gemini-3-flash-preview":
            return AppPreferences.gemini3FlashThinkingLevel
        default:
            return nil
        }
    }

    private static let responsesAPIPaths: Set<String> = [
        "/v1/responses",
        "/api/v1/responses"
    ]

    private func isResponsesAPIPath(_ path: String) -> Bool {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        return Self.responsesAPIPaths.contains(normalizedPath)
    }

    private func isGeminiModel(_ bodyString: String) -> Bool {
        guard let jsonData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = json["model"] as? String else {
            return false
        }
        return model.hasPrefix("gemini-")
    }

    private func rewriteModelValue(in json: String, from oldModel: String, to newModel: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: oldModel)
        let pattern = "(\"model\"\\s*:\\s*\")\(escaped)(\")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let matchRange = Range(match.range, in: json) else {
            NSLog("[ThinkingProxy] Warning: Could not find model value '\(oldModel)' for rewrite")
            return json
        }
        var result = json
        let replacement = "\"model\":\"\(newModel)\""
        result.replaceSubrange(matchRange, with: replacement)
        return result
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

    private func lastNonWhitespaceIndex(in json: String) -> String.Index? {
        var index = json.endIndex
        while index > json.startIndex {
            index = json.index(before: index)
            if !json[index].isWhitespace {
                return index
            }
        }
        return nil
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
    private func forwardRequest(method: String, path: String, version: String, headers: [(String, String)], body: String, originalConnection: NWConnection, retryWithApiPrefix: Bool = false) {
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
                            // Receive response from CLIProxyAPI (with 404 retry capability)
                            let normalizeAmpProviderResponse = self.shouldNormalizeAmpProviderResponse(for: path)
                            if retryWithApiPrefix {
                                self.receiveResponseWith404Retry(from: targetConnection, originalConnection: originalConnection, 
                                                                 method: method, path: path, version: version, 
                                                                 headers: headers, body: body,
                                                                 normalizeAmpProviderResponse: normalizeAmpProviderResponse)
                            } else {
                                self.receiveResponse(from: targetConnection,
                                                     originalConnection: originalConnection,
                                                     normalizeAmpProviderResponse: normalizeAmpProviderResponse)
                            }
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
     Receives response and retries with /api/ prefix on 404
     */
    private func receiveResponseWith404Retry(from targetConnection: NWConnection, originalConnection: NWConnection, 
                                             method: String, path: String, version: String, 
                                             headers: [(String, String)], body: String,
                                             normalizeAmpProviderResponse: Bool) {
        let rewriteState = normalizeAmpProviderResponse ? AmpProviderRewriteState() : nil
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[ThinkingProxy] Receive error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                // Check if response is a 404
                if let responseString = String(data: data, encoding: .utf8) {
                    // Log first 200 chars to debug
                    let preview = String(responseString.prefix(200))
                    NSLog("[ThinkingProxy] Response preview for \(path): \(preview)")
                    
                    // Check for 404 in status line OR in body
                    let is404 = responseString.contains("HTTP/1.1 404") || 
                               responseString.contains("HTTP/1.0 404") ||
                               responseString.contains("404 page not found")
                    
                    if is404 {
                        // Check if path doesn't already start with /api/
                        if !path.starts(with: "/api/") && !path.starts(with: "/v1/") {
                            NSLog("[ThinkingProxy] Got 404 for \(path), retrying with /api prefix")
                            targetConnection.cancel()
                            
                            // Retry with /api/ prefix
                            let newPath = "/api" + path
                            self.forwardRequest(method: method, path: newPath, version: version, headers: headers, 
                                              body: body, originalConnection: originalConnection, retryWithApiPrefix: false)
                            return
                        }
                    }
                }
                
                // Not a 404 or already has /api/, forward response as-is
                var outboundData = data
                if let rewriteState {
                    outboundData = self.normalizeAmpProviderResponseChunk(data, rewriteState: rewriteState, isComplete: isComplete)
                }

                if outboundData.isEmpty && !isComplete {
                    self.streamNextChunk(from: targetConnection, to: originalConnection, rewriteState: rewriteState)
                    return
                }

                originalConnection.send(content: outboundData, completion: .contentProcessed({ sendError in
                    if let sendError = sendError {
                        NSLog("[ThinkingProxy] Send error: \(sendError)")
                    }
                    
                    if isComplete {
                        targetConnection.cancel()
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                            originalConnection.cancel()
                        }))
                    } else {
                        // Continue streaming
                        self.streamNextChunk(from: targetConnection, to: originalConnection, rewriteState: rewriteState)
                    }
                }))
            } else if isComplete {
                targetConnection.cancel()
                if let carryData = self.flushNormalizedResponseCarry(rewriteState), !carryData.isEmpty {
                    originalConnection.send(content: carryData, completion: .contentProcessed({ _ in
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                            originalConnection.cancel()
                        }))
                    }))
                } else {
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                        originalConnection.cancel()
                    }))
                }
            }
        }
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
}
