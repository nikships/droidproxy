import Foundation

class CodexUsageProbe {
    struct JSONRPCRequest: Codable {
        let jsonrpc: String
        let id: Int
        let method: String
        let params: [String: String]?
    }

    struct JSONRPCNotification: Codable {
        let jsonrpc: String
        let method: String
    }

    struct JSONRPCResponse: Codable {
        let jsonrpc: String
        let id: Int
        let result: [String: AnyCodable]?
        let error: AnyCodable?
    }

    struct AnyCodable: Codable {
        let value: Any
        
        init(_ value: Any) {
            self.value = value
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) { value = intVal }
            else if let doubleVal = try? container.decode(Double.self) { value = doubleVal }
            else if let stringVal = try? container.decode(String.self) { value = stringVal }
            else if let boolVal = try? container.decode(Bool.self) { value = boolVal }
            else if let dictVal = try? container.decode([String: AnyCodable].self) {
                var dict = [String: Any]()
                for (k, v) in dictVal { dict[k] = v.value }
                value = dict
            }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable unsupported type") }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let intVal = value as? Int { try container.encode(intVal) }
            else if let doubleVal = value as? Double { try container.encode(doubleVal) }
            else if let stringVal = value as? String { try container.encode(stringVal) }
            else if let boolVal = value as? Bool { try container.encode(boolVal) }
            else { throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AnyCodable unsupported type")) }
        }
    }

    func fetchUsage() async -> ProviderUsageSnapshot {
        do {
            if !codexCLIInstalled() {
                return ProviderUsageSnapshot(provider: "Codex", lastUpdated: Date(), windows: [], error: "Codex CLI not installed")
            }
            return try await executeJSONRPC()
        } catch {
            return ProviderUsageSnapshot(provider: "Codex", lastUpdated: Date(), windows: [], error: error.localizedDescription)
        }
    }

    private func codexCLIInstalled() -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "which codex"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func executeJSONRPC() async throws -> ProviderUsageSnapshot {
        let task = Process()
        task.launchPath = "/bin/sh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Augment PATH just in case it's in homebrew or local bin
        task.arguments = ["-c", "PATH=$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin codex -s read-only -a untrusted app-server"]
        task.currentDirectoryPath = home
        
        let pipeOut = Pipe()
        let pipeIn = Pipe()
        task.standardOutput = pipeOut
        task.standardInput = pipeIn
        
        try task.run()
        
        // Send initialize
        let initReq = JSONRPCRequest(jsonrpc: "2.0", id: 1, method: "initialize", params: nil)
        let initData = try JSONEncoder().encode(initReq)
        let initStr = String(data: initData, encoding: .utf8)!
        let initHeader = "Content-Length: \(initData.count)\r\n\r\n"
        try pipeIn.fileHandleForWriting.write(contentsOf: Data((initHeader + initStr).utf8))
        
        // Read initialized / respond
        // This is a simplified sequential read just to grab the rateLimits after initialization
        
        // Wait briefly for init to process, then send read request
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let readReq = JSONRPCRequest(jsonrpc: "2.0", id: 2, method: "account/rateLimits/read", params: nil)
        let readData = try JSONEncoder().encode(readReq)
        let readStr = String(data: readData, encoding: .utf8)!
        let readHeader = "Content-Length: \(readData.count)\r\n\r\n"
        try pipeIn.fileHandleForWriting.write(contentsOf: Data((readHeader + readStr).utf8))
        
        // Wait for response
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Terminate so we can read whatever was buffered
        task.terminate()
        let outData = pipeOut.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        
        // Parse JSON-RPC responses (quick hack: find the result object for id 2)
        var windows = [UsageWindow]()
        let components = outStr.components(separatedBy: "Content-Length: ")
        for comp in components {
            if let range = comp.range(of: "\r\n\r\n") {
                let jsonStr = String(comp[range.upperBound...])
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let id = json["id"] as? Int, id == 2,
                   let result = json["result"] as? [String: Any],
                   let rateLimits = result["rateLimits"] as? [String: Any] {
                    
                    if let primary = rateLimits["primary"] as? [String: Any],
                       let percent = primary["usedPercent"] as? Double {
                        windows.append(UsageWindow(kind: .other, limit: 100, used: Int(percent), percentUsed: percent, resetsAt: Date().addingTimeInterval(4*3600))) // Placeholder limit/resets
                    }
                    if let secondary = rateLimits["secondary"] as? [String: Any],
                       let percent = secondary["usedPercent"] as? Double {
                        windows.append(UsageWindow(kind: .weekly, limit: 100, used: Int(percent), percentUsed: percent, resetsAt: nil))
                    }
                    break
                }
            }
        }
        
        return ProviderUsageSnapshot(provider: "Codex", lastUpdated: Date(), windows: windows, error: windows.isEmpty ? "Failed to parse rate limits" : nil)
    }
}
