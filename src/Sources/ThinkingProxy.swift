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
 - Rewrites Gemini `/v1/responses` to `/v1/chat/completions` since the backend does not
   support Gemini via the Responses API endpoint.

 JSON edits and hot-path inspections are surgical (no full JSON re-serialization) so
 Anthropic prompt-cache key ordering is preserved and large prompts avoid parse overhead.
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
        startListener(allowCustomBindAddress: true)
    }

    /// Creates and starts the listener. When `allowCustomBindAddress` is true the
    /// user-configured bind address is applied; if the listener then fails (for
    /// example the address is malformed or not assigned to any local interface)
    /// it retries once with `allowCustomBindAddress` false, falling back to the
    /// default all-interfaces bind so a bad address can't leave the proxy down.
    private func startListener(allowCustomBindAddress: Bool) {
        guard !isRunning else {
            NSLog("[ThinkingProxy] Already running")
            return
        }

        let bindAddress = AppPreferences.bindAddress
        let useCustomBind = allowCustomBindAddress && bindAddress != "0.0.0.0"

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            guard let port = NWEndpoint.Port(rawValue: proxyPort) else {
                NSLog("[ThinkingProxy] Invalid port: %d", proxyPort)
                return
            }

            // If a specific bind address is set (and it's not 0.0.0.0), restrict the listener to it.
            // 0.0.0.0 means bind to all interfaces, which is the default behavior when
            // requiredLocalEndpoint is not set.
            if useCustomBind {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(bindAddress), port: port)
                NSLog("[ThinkingProxy] Binding to \(bindAddress):\(proxyPort)")
            } else if !allowCustomBindAddress {
                NSLog("[ThinkingProxy] Falling back to all interfaces after bind failure: \(proxyPort)")
            } else {
                NSLog("[ThinkingProxy] Binding to all interfaces (0.0.0.0):\(proxyPort)")
            }

            let newListener = try NWListener(using: parameters, on: port)
            listener = newListener

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
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
                    // A custom bind address may be invalid or unavailable on this
                    // machine, leaving the listener failed. Fall back once to the
                    // default all-interfaces bind so the proxy keeps working.
                    if useCustomBind {
                        NSLog("[ThinkingProxy] Bind to \(bindAddress) failed; retrying on all interfaces")
                        newListener?.stateUpdateHandler = nil
                        newListener?.cancel()
                        if self?.listener === newListener {
                            self?.listener = nil
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            self?.startListener(allowCustomBindAddress: false)
                        }
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

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: .global(qos: .userInitiated))

        } catch {
            NSLog("[ThinkingProxy] Failed to start: \(error)")
            // NWListener init can also throw for an invalid required endpoint;
            // fall back to the default bind so a bad address isn't fatal.
            if useCustomBind {
                NSLog("[ThinkingProxy] Retrying on all interfaces after start failure")
                startListener(allowCustomBindAddress: false)
            }
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
            guard let headerEndRange = newAccumulatedData.range(of: headerEndPattern) else {
                if isComplete {
                    // Complete but malformed (no headers end found); process what we have.
                    self.processRequest(data: newAccumulatedData, connection: connection)
                } else {
                    // Haven't found header end yet; schedule next iteration.
                    self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
                }
                return
            }

            // If Content-Length advertises more bytes than we've received and the
            // stream is still open, keep reading. Otherwise (full body, missing
            // header, or truncated stream) hand off to processRequest.
            let bodyReceived = newAccumulatedData.count - headerEndRange.upperBound
            if !isComplete,
               let contentLength = self.parseContentLength(in: newAccumulatedData[..<headerEndRange.upperBound]),
               bodyReceived < contentLength {
                self.receiveNextChunk(from: connection, accumulatedData: newAccumulatedData)
                return
            }

            self.processRequest(data: newAccumulatedData, connection: connection)
        }
    }

    /// Parses the `Content-Length` value from the raw header bytes of an HTTP
    /// request. Returns nil if the header is missing or unparseable.
    private func parseContentLength(in headerData: Data) -> Int? {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        for line in headerString.components(separatedBy: "\r\n")
            where line.lowercased().hasPrefix("content-length:") {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
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

        let bodyString = String(requestString[bodyStartRange.upperBound...])

        var rewrittenPath = path

        // Try to parse and modify JSON body for POST requests
        var modifiedBody = bodyString
        var requestFields: RequestJSONFields? = bodyString.isEmpty ? nil : inspectRequestJSONFields(in: bodyString)

        if method == "POST" && !bodyString.isEmpty {
            ThinkingProxy.fileLog("INCOMING REQUEST: \(method) \(rewrittenPath)")
            if let result = rewriteAntigravityModelAlias(jsonString: modifiedBody, fields: requestFields) {
                modifiedBody = result
                requestFields = inspectRequestJSONFields(in: modifiedBody)
            }
            if isCursorModel(requestFields) {
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
                if let result = rewriteCursorModelAlias(jsonString: modifiedBody, fields: requestFields) {
                    modifiedBody = result
                    requestFields = inspectRequestJSONFields(in: modifiedBody)
                }
                forwardToCursor(method: method, path: rewrittenPath, version: httpVersion, headers: headers, body: modifiedBody, originalConnection: connection)
                return
            }
            if let result = processOpenAIFastMode(jsonString: modifiedBody, path: rewrittenPath, fields: requestFields) {
                modifiedBody = result
                requestFields = inspectRequestJSONFields(in: modifiedBody)
            }
            if let model = requestFields?.model, isClaudeModel(model) {
                let sanitizedBody = ClaudeThinkingBlockSanitizer.sanitize(modifiedBody)
                if sanitizedBody != modifiedBody {
                    ThinkingProxy.fileLog("SANITIZED CLAUDE THINKING BLOCKS: stripped stale assistant thinking before forwarding")
                    modifiedBody = sanitizedBody
                    requestFields = inspectRequestJSONFields(in: modifiedBody)
                }
            }
            if let summary = reasoningSummaryLog(in: modifiedBody, fields: requestFields) {
                ThinkingProxy.fileLog("REQUEST REASONING: \(summary)")
            }
        }

        // Rewrite /v1/responses to /v1/chat/completions only for OAuth Code Assist
        // Gemini models (the `-preview` suffixed ones served by the gemini-cli executor),
        // which do not support the Responses API endpoint. Antigravity-routed Gemini
        // models (e.g. `gemini-3-flash`, `gemini-pro-agent`) DO support /v1/responses
        // natively, so we must NOT rewrite their path — doing so would cause the
        // backend to return chat-completions SSE that Droid CLI can't parse, hanging
        // the stream.
        if isResponsesAPIPath(rewrittenPath) && isOAuthCodeAssistGeminiModel(requestFields) {
            let newPath = rewrittenPath.replacingOccurrences(of: "/responses", with: "/chat/completions")
            NSLog("[ThinkingProxy] Rewriting OAuth-Gemini responses path: \(rewrittenPath) -> \(newPath)")
            ThinkingProxy.fileLog("REWRITE PATH: \(rewrittenPath) -> \(newPath) (OAuth Code Assist Gemini model)")
            rewrittenPath = newPath
        }

        let forwardHeaders = headersForForwarding(headers, requestFields: requestFields)
        forwardRequest(method: method, path: rewrittenPath, version: httpVersion, headers: forwardHeaders, body: modifiedBody, originalConnection: connection)
    }

    private func headersForForwarding(_ headers: [(String, String)], requestFields: RequestJSONFields?) -> [(String, String)] {
        guard shouldRequestVisibleClaudeThinking(requestFields) else {
            return headers
        }

        ThinkingProxy.fileLog("CLAUDE visible thinking enabled: removing \(Config.claudeRedactedThinkingBeta) from Anthropic-Beta")
        return headersWithVisibleClaudeThinkingBetas(headers)
    }

    private func shouldRequestVisibleClaudeThinking(_ requestFields: RequestJSONFields?) -> Bool {
        guard let model = requestFields?.model,
              isClaudeModel(model),
              let thinkingType = requestFields?.thinkingType else {
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

    private static let antigravityModelAliases: [String: String] = [
        "ag-c46s-thinking": "claude-sonnet-4-6",
        "ag-c46o-thinking": "claude-opus-4-6-thinking"
    ]

    private static let cursorModelAliases: [String: String] = [
        "cursor-composer-2.5": "composer-2.5"
    ]

    private func rewriteAntigravityModelAlias(jsonString: String, fields: RequestJSONFields?) -> String? {
        guard let model = fields?.model,
              let modelLocation = fields?.modelLocation,
              let backendModel = Self.antigravityModelAliases[model] else {
            return nil
        }

        var result = jsonString
        result.replaceSubrange(modelLocation.valueRange, with: "\"\(backendModel)\"")
        ThinkingProxy.fileLog("REWRITE MODEL: \(model) -> \(backendModel) (Antigravity alias)")
        return result
    }

    private func rewriteCursorModelAlias(jsonString: String, fields: RequestJSONFields?) -> String? {
        guard let model = fields?.model,
              let modelLocation = fields?.modelLocation,
              let backendModel = Self.cursorModelAliases[model] else {
            return nil
        }

        var result = jsonString
        result.replaceSubrange(modelLocation.valueRange, with: "\"\(backendModel)\"")
        ThinkingProxy.fileLog("REWRITE MODEL: \(model) -> \(backendModel) (Cursor alias)")
        return result
    }

    private func objectStringField(in jsonString: String,
                                   objectRange: Range<String.Index>,
                                   key: String) -> (value: String, location: TopLevelFieldLocation)? {
        guard let location = findObjectFieldLocation(in: jsonString, key: key, objectRange: objectRange),
              jsonString[location.valueRange.lowerBound] == "\"",
              let (value, valueEnd) = parseJSONStringToken(in: jsonString,
                                                           startingAt: location.valueRange.lowerBound,
                                                           before: location.valueRange.upperBound),
              valueEnd == location.valueRange.upperBound else {
            return nil
        }

        return (value, location)
    }

    private static let responsesAPIPaths: Set<String> = [
        "/v1/responses",
        "/api/v1/responses"
    ]

    private func isResponsesAPIPath(_ path: String) -> Bool {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        return Self.responsesAPIPaths.contains(normalizedPath)
    }

    private struct RequestJSONFields {
        let model: String?
        let modelLocation: TopLevelFieldLocation?
        let thinkingType: String?
        let thinkingLocation: TopLevelFieldLocation?
        let serviceTierLocation: TopLevelFieldLocation?

        var hasServiceTier: Bool { serviceTierLocation != nil }
    }

    /// Keys needed for actual request routing / header / fast-mode decisions.
    /// Kept small so the top-level JSON scan can early-exit before traversing
    /// the (potentially huge) `messages` array on most requests.
    private static let routingInspectionKeys: Set<String> = [
        "model",
        "service_tier",
        "thinking"
    ]

    /// Additional keys only needed to build the human-readable REQUEST REASONING
    /// debug log line. Scanned separately (and only when about to log) so a
    /// missing optional key here never forces routing to consume `messages`.
    private static let reasoningLogInspectionKeys: Set<String> = [
        "reasoning",
        "reasoning_effort",
        "output_config",
        "generationConfig"
    ]

    /// Stable display order for the REQUEST REASONING summary line.
    private static let reasoningSummaryOrder = [
        "reasoning",
        "reasoning_effort",
        "thinking",
        "output_config",
        "service_tier",
        "generationConfig"
    ]

    /// Maximum chars from a single field's raw JSON we include in the
    /// REQUEST REASONING log line, to avoid emitting megabyte-long lines
    /// when a client passes a giant `reasoning`/`output_config` object.
    private static let reasoningSummarySnippetLimit = 512

    private func inspectRequestJSONFields(in bodyString: String) -> RequestJSONFields? {
        guard let locations = findTopLevelFieldLocations(in: bodyString, keys: Self.routingInspectionKeys) else {
            return nil
        }

        let modelLocation = locations["model"]
        let model = modelLocation.flatMap { topLevelStringValue(in: bodyString, location: $0) }
        let thinkingLocation = locations["thinking"]
        let thinkingType = thinkingLocation.flatMap {
            objectStringField(in: bodyString, objectRange: $0.valueRange, key: "type")?.value
        }
        return RequestJSONFields(model: model,
                                 modelLocation: modelLocation,
                                 thinkingType: thinkingType,
                                 thinkingLocation: thinkingLocation,
                                 serviceTierLocation: locations["service_tier"])
    }

    /// Builds the REQUEST REASONING log line by doing a second, narrowly-scoped
    /// scan for the debug-only keys. Returns nil when nothing useful is present
    /// (so we don't emit empty/noise lines).
    private func reasoningSummaryLog(in bodyString: String, fields: RequestJSONFields?) -> String? {
        var locations = findTopLevelFieldLocations(in: bodyString, keys: Self.reasoningLogInspectionKeys) ?? [:]
        locations["thinking"] = fields?.thinkingLocation
        locations["service_tier"] = fields?.serviceTierLocation

        var parts: [String] = []
        if let model = fields?.model {
            parts.append("model=\(model)")
        }

        for key in Self.reasoningSummaryOrder {
            guard let field = locations[key] else { continue }
            let raw = bodyString[field.valueRange]
            let snippet = String(raw.prefix(Self.reasoningSummarySnippetLimit))
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            parts.append("\(key)=\(snippet)")
        }

        // Only the `model=...` part (or nothing) means we have no
        // reasoning/thinking info worth logging.
        if parts.count <= 1 { return nil }
        return parts.joined(separator: " ")
    }

    private func topLevelStringValue(in jsonString: String, location: TopLevelFieldLocation) -> String? {
        guard jsonString[location.valueRange.lowerBound] == "\"",
              let (value, valueEnd) = parseJSONStringToken(in: jsonString,
                                                           startingAt: location.valueRange.lowerBound,
                                                           before: location.valueRange.upperBound),
              valueEnd == location.valueRange.upperBound else {
            return nil
        }

        return value
    }

    /// True only for Gemini models served by the OAuth Code Assist (`gemini-cli`)
    /// executor — these are the `-preview`-suffixed names like
    /// `gemini-3.1-pro-preview` and `gemini-3-flash-preview`. The Code Assist
    /// executor does not implement the Responses API, so we rewrite the path to
    /// `/v1/chat/completions` for them. Antigravity-routed Gemini models support
    /// `/v1/responses` natively and must NOT be rewritten.
    private func isOAuthCodeAssistGeminiModel(_ requestFields: RequestJSONFields?) -> Bool {
        guard let model = requestFields?.model else {
            return false
        }
        return model.hasPrefix("gemini-") && model.hasSuffix("-preview")
    }

    // MARK: - Surgical JSON string helpers
    // These scan the top-level JSON object and modify specific fields in-place, preserving
    // the original JSON structure and key ordering. This is critical because
    // JSONSerialization.data() reorders keys alphabetically, which breaks Anthropic's
    // prompt cache matching.

    private struct TopLevelFieldLocation {
        let pairRange: Range<String.Index>
        let valueRange: Range<String.Index>
    }

    private func findTopLevelFieldLocations(in json: String, keys targetKeys: Set<String>) -> [String: TopLevelFieldLocation]? {
        findObjectFieldLocations(in: json, keys: targetKeys, objectRange: json.startIndex..<json.endIndex)
    }

    private func findObjectFieldLocation(in json: String,
                                         key targetKey: String,
                                         objectRange: Range<String.Index>) -> TopLevelFieldLocation? {
        findObjectFieldLocations(in: json, keys: [targetKey], objectRange: objectRange)?[targetKey]
    }

    private func findObjectFieldLocations(in json: String,
                                          keys targetKeys: Set<String>,
                                          objectRange: Range<String.Index>) -> [String: TopLevelFieldLocation]? {
        guard var index = firstNonWhitespaceIndex(in: json,
                                                  from: objectRange.lowerBound,
                                                  before: objectRange.upperBound),
              json[index] == "{" else {
            return nil
        }

        if targetKeys.isEmpty {
            return [:]
        }

        var locations: [String: TopLevelFieldLocation] = [:]
        index = json.index(after: index)

        while true {
            guard let keyStart = firstNonWhitespaceIndex(in: json,
                                                         from: index,
                                                         before: objectRange.upperBound) else {
                return nil
            }

            let token = json[keyStart]
            if token == "}" {
                return locations
            }
            guard token == "\"" else {
                return nil
            }

            guard let (key, keyEnd) = parseJSONStringToken(in: json,
                                                           startingAt: keyStart,
                                                           before: objectRange.upperBound),
                  let colonIndex = firstNonWhitespaceIndex(in: json,
                                                           from: keyEnd,
                                                           before: objectRange.upperBound),
                  json[colonIndex] == ":" else {
                return nil
            }

            let afterColon = json.index(after: colonIndex)
            guard let valueStart = firstNonWhitespaceIndex(in: json,
                                                           from: afterColon,
                                                           before: objectRange.upperBound),
                  let valueEnd = consumeJSONValue(in: json,
                                                  startingAt: valueStart,
                                                  before: objectRange.upperBound) else {
                return nil
            }

            if targetKeys.contains(key), locations[key] == nil {
                locations[key] = TopLevelFieldLocation(pairRange: keyStart..<valueEnd,
                                                       valueRange: valueStart..<valueEnd)
                if locations.count == targetKeys.count {
                    return locations
                }
            }

            guard let delimiterIndex = firstNonWhitespaceIndex(in: json,
                                                               from: valueEnd,
                                                               before: objectRange.upperBound) else {
                return nil
            }

            let delimiter = json[delimiterIndex]
            if delimiter == "," {
                index = json.index(after: delimiterIndex)
                continue
            }
            if delimiter == "}" {
                return locations
            }
            return nil
        }
    }

    private func firstNonWhitespaceIndex(in json: String,
                                         from start: String.Index,
                                         before end: String.Index) -> String.Index? {
        var index = start
        while index < end, json[index].isWhitespace {
            index = json.index(after: index)
        }
        return index < end ? index : nil
    }

    private func parseJSONStringToken(in json: String,
                                      startingAt startQuote: String.Index,
                                      before end: String.Index) -> (String, String.Index)? {
        guard json[startQuote] == "\"" else {
            return nil
        }

        var index = json.index(after: startQuote)
        var escaped = false

        while index < end {
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

    private func consumeJSONValue(in json: String,
                                  startingAt start: String.Index,
                                  before end: String.Index) -> String.Index? {
        guard start < end else {
            return nil
        }

        let first = json[start]
        if first == "\"" {
            return parseJSONStringToken(in: json, startingAt: start, before: end)?.1
        }

        if first == "{" || first == "[" {
            return consumeCompositeJSONValue(in: json, startingAt: start, before: end)
        }

        var index = start
        while index < end {
            let char = json[index]
            if char == "," || char == "}" || char == "]" || char.isWhitespace {
                break
            }
            index = json.index(after: index)
        }

        return index > start ? index : nil
    }

    private func consumeCompositeJSONValue(in json: String,
                                           startingAt start: String.Index,
                                           before end: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false

        while index < end {
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

    private func processOpenAIFastMode(jsonString: String, path: String, fields: RequestJSONFields?) -> String? {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        guard Self.fastTierEligibleResponsePaths.contains(normalizedPath) else { return nil }

        guard let fields, let model = fields.model, let modelLocation = fields.modelLocation else {
            return nil
        }

        switch model {
        case "gpt-5.4":
            guard AppPreferences.gpt54FastMode else { return nil }
        case "gpt-5.5":
            guard AppPreferences.gpt55FastMode else { return nil }
        case "gpt-5.3-codex":
            guard AppPreferences.gpt53CodexFastMode else { return nil }
        default:
            return nil
        }

        guard !fields.hasServiceTier else { return nil }

        var result = jsonString
        result.insert(contentsOf: ",\"service_tier\":\"priority\"", at: modelLocation.pairRange.upperBound)
        NSLog("[ThinkingProxy] Injected service_tier=priority for model '\(model)' on path \(path)")
        ThinkingProxy.fileLog("INJECTED service_tier=priority for model \(model)")
        return result
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
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
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
                            self.receiveResponse(from: targetConnection,
                                                 originalConnection: originalConnection)
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
                                 originalConnection: NWConnection) {
        // Start the streaming loop
        streamNextChunk(from: targetConnection, to: originalConnection)
    }
    
    /**
     Streams response chunks iteratively (uses async scheduling instead of recursion to avoid stack buildup)
     */
    private func streamNextChunk(from targetConnection: NWConnection,
                                 to originalConnection: NWConnection) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[ThinkingProxy] Receive response error: \(error)")
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                // Forward response chunk to original client
                originalConnection.send(content: data, completion: .contentProcessed({ sendError in
                    if let sendError = sendError {
                        NSLog("[ThinkingProxy] Send response error: \(sendError)")
                    }

                    if isComplete {
                        self.finishStreaming(target: targetConnection, client: originalConnection)
                    } else {
                        // Schedule next iteration of the streaming loop
                        self.streamNextChunk(from: targetConnection, to: originalConnection)
                    }
                }))
            } else if isComplete {
                targetConnection.cancel()
                // Always close client connection - no keep-alive/pipelining support
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    originalConnection.cancel()
                }))
            }
        }
    }

    /**
     Cancels the target connection and signals end-of-stream to the client before
     cancelling it as well. Safe to call even if `target` has already been
     cancelled — `NWConnection.cancel()` is idempotent.
     */
    private func finishStreaming(target: NWConnection, client: NWConnection) {
        target.cancel()
        client.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
            client.cancel()
        }))
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

    // MARK: - Cursor API Proxying
    
    private func isCursorModel(_ requestFields: RequestJSONFields?) -> Bool {
        guard let model = requestFields?.model else {
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

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    self.finishStreaming(target: targetConnection, client: originalConnection)
                }
                return
            }

            originalConnection.send(content: data, completion: .contentProcessed({ sendError in
                if let sendError = sendError {
                    NSLog("[ThinkingProxy] Send Cursor response error: \(sendError)")
                }

                if isComplete {
                    self.finishStreaming(target: targetConnection, client: originalConnection)
                } else {
                    self.receiveCursorResponse(from: targetConnection, originalConnection: originalConnection)
                }
            }))
        }
    }
}
