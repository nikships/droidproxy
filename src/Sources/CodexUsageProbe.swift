import Foundation

class CodexUsageProbe {
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
        task.arguments = ["-c", "PATH=$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin which codex"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func executeJSONRPC() async throws -> ProviderUsageSnapshot {
        let task = Process()
        task.launchPath = "/bin/sh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        task.arguments = ["-c", "PATH=$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin codex -s read-only -a untrusted app-server"]
        task.currentDirectoryPath = home

        let pipeOut = Pipe()
        let pipeIn = Pipe()
        task.standardOutput = pipeOut
        task.standardInput = pipeIn
        task.standardError = Pipe()

        try task.run()

        let initLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"droidproxy","version":"1.0.0"}}}"# + "\n"
        try pipeIn.fileHandleForWriting.write(contentsOf: Data(initLine.utf8))

        try await Task.sleep(nanoseconds: 500_000_000)

        let readLine = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"# + "\n"
        try pipeIn.fileHandleForWriting.write(contentsOf: Data(readLine.utf8))

        try await Task.sleep(nanoseconds: 1_500_000_000)

        task.terminate()
        let outData = pipeOut.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""

        var windows = [UsageWindow]()
        var parseError: String? = nil

        for line in outStr.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                continue
            }
            guard let id = json["id"] as? Int, id == 2 else { continue }

            if let err = json["error"] as? [String: Any] {
                parseError = (err["message"] as? String) ?? "Unknown JSON-RPC error"
                break
            }

            guard let result = json["result"] as? [String: Any],
                  let rateLimits = result["rateLimits"] as? [String: Any] else {
                continue
            }

            windows.append(contentsOf: Self.parseWindows(from: rateLimits))
            break
        }

        let error: String? = {
            if let parseError { return parseError }
            return windows.isEmpty ? "Failed to parse rate limits" : nil
        }()

        return ProviderUsageSnapshot(provider: "Codex", lastUpdated: Date(), windows: windows, error: error)
    }

    private static func parseWindows(from rateLimits: [String: Any]) -> [UsageWindow] {
        var windows = [UsageWindow]()
        for (key, kind) in [("primary", UsageWindowKind.other), ("secondary", UsageWindowKind.weekly)] {
            guard let bucket = rateLimits[key] as? [String: Any],
                  let percent = (bucket["usedPercent"] as? NSNumber)?.doubleValue else {
                continue
            }
            let durationMins = (bucket["windowDurationMins"] as? NSNumber)?.doubleValue
            let resetsAtEpoch = (bucket["resetsAt"] as? NSNumber)?.doubleValue
            let resetsAt: Date? = {
                if let resetsAtEpoch { return Date(timeIntervalSince1970: resetsAtEpoch) }
                if let durationMins { return Date().addingTimeInterval(durationMins * 60) }
                return nil
            }()
            windows.append(UsageWindow(kind: kind, limit: 0, used: 0, percentUsed: percent, resetsAt: resetsAt))
        }
        return windows
    }
}
