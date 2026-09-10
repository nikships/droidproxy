import Combine
import Foundation

/// Lifecycle of the local `cursor-api-proxy` child. Mirrors Copilot: `Process.run()`
/// only means `npx` spawned, so readiness is a localhost `/healthz` probe.
enum CursorAgentProxyState: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var failureDescription: String? {
        guard case .failed(let detail) = self else { return nil }
        return detail
    }
}

enum CursorAgentProxyError: LocalizedError {
    case nodeNotInstalled
    case agentNotInstalled
    case agentNotLoggedIn
    case failedToStart(String)
    case stoppedUnexpectedly(String)
    case neverBecameReady(String?)

    var errorDescription: String? {
        switch self {
        case .nodeNotInstalled:
            return "Node.js 18 or later is required for Cursor CLI proxying. Install Node.js, then try again."
        case .agentNotInstalled:
            return "Cursor Agent CLI is not installed. Run `curl https://cursor.com/install -fsS | bash`, then `agent login`."
        case .agentNotLoggedIn:
            return "Cursor Agent CLI is not logged in. Run `agent login`, then retry."
        case .failedToStart(let detail):
            return "Could not start the local Cursor agent proxy: \(detail)"
        case .stoppedUnexpectedly(let detail):
            return "The local Cursor agent proxy stopped unexpectedly: \(detail)"
        case .neverBecameReady(let detail):
            guard let detail, !detail.isEmpty else {
                return "The local Cursor agent proxy never started serving requests on port \(CursorAgentProxyManager.proxyPort)."
            }
            return "The local Cursor agent proxy never started serving requests on port \(CursorAgentProxyManager.proxyPort): \(detail)"
        }
    }
}

/// Spawns the maintained `cursor-api-proxy` npm package and points it at the
/// local Cursor `agent` / `cursor-agent` CLI (already authenticated via
/// `agent login`). ThinkingProxy forwards `cursor-*` models here instead of
/// the old hosted `api-for-cursor.standardagents.ai` API-key path.
final class CursorAgentProxyManager: ObservableObject {
    static let proxyPort: UInt16 = 8320
    static let proxyHost = "127.0.0.1"
    static let proxyBaseURL = "http://\(proxyHost):\(proxyPort)"
    static let packageSpecifier = "cursor-api-proxy@1.3.0"

    private enum ProcessTiming {
        static let gracefulTerminationTimeout: TimeInterval = 2.0
        static let terminationPollInterval: TimeInterval = 0.05
    }

    private enum ReadinessTiming {
        static let timeout: TimeInterval = 90
        static let pollInterval: TimeInterval = 0.5
        static let probeTimeout: TimeInterval = 3
    }

    @Published private(set) var state: CursorAgentProxyState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var loginEmail: String?

    private var proxyProcess: Process?
    private var proxyOutputPipes: [Pipe] = []
    private var isolatedProcessGroups = Set<pid_t>()
    private var proxyTranscript: ProcessTranscript?
    private var readinessGeneration = 0

    var isRunning: Bool {
        state == .running
    }

    static var isAgentInstalled: Bool {
        agentExecutableURL() != nil
    }

    static var isAgentAuthenticated: Bool {
        currentLoginEmail() != nil
    }

    func start(completion: ((Bool) -> Void)? = nil) {
        if let proxyProcess, proxyProcess.isRunning, state == .running || state == .starting {
            completion?(state == .running)
            return
        }

        guard Self.agentExecutableURL() != nil else {
            fail(with: .agentNotInstalled)
            completion?(false)
            return
        }

        guard let email = Self.currentLoginEmail() else {
            fail(with: .agentNotLoggedIn)
            completion?(false)
            return
        }
        loginEmail = email

        guard let npxURL = Self.npxExecutableURL() else {
            fail(with: .nodeNotInstalled)
            completion?(false)
            return
        }

        let process = Process()
        process.executableURL = npxURL
        process.arguments = ["--yes", Self.packageSpecifier]
        process.environment = Self.proxyEnvironment(npxURL: npxURL)

        let transcript = ProcessTranscript()
        proxyTranscript = transcript
        proxyOutputPipes = attachOutputPipes(to: process) { text in
            transcript.append(text)
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            DispatchQueue.main.async {
                guard let self, self.proxyProcess === process else { return }
                self.proxyProcess = nil
                self.clearProxyOutputPipes()
                self.readinessGeneration += 1
                let detail = transcript.failureDetail(exitCode: terminatedProcess.terminationStatus)
                self.proxyTranscript = nil
                NSLog("[CursorAgentProxy] Local proxy exited (status %d): %@",
                      terminatedProcess.terminationStatus, detail ?? "no output")
                self.fail(with: .stoppedUnexpectedly(detail ?? "exit code \(terminatedProcess.terminationStatus)"))
            }
        }

        do {
            try process.run()
            isolateProcessGroup(for: process)
            proxyProcess = process
            state = .starting
            lastError = nil
            NSLog("[CursorAgentProxy] Launched local proxy on port %d, waiting for readiness", Self.proxyPort)
            waitForReadiness(of: process, transcript: transcript, completion: completion)
        } catch {
            clearProxyOutputPipes()
            proxyTranscript = nil
            fail(with: .failedToStart(error.localizedDescription))
            completion?(false)
        }
    }

    func stop() {
        stopProxy()
        state = .idle
        lastError = nil
    }

    func refreshLoginStatus() {
        loginEmail = Self.currentLoginEmail()
    }

    private func stopProxy() {
        readinessGeneration += 1
        if let proxyProcess {
            proxyProcess.terminationHandler = nil
            terminate(proxyProcess)
        }
        proxyProcess = nil
        proxyTranscript = nil
        clearProxyOutputPipes()
    }

    private func waitForReadiness(
        of process: Process,
        transcript: ProcessTranscript,
        completion: ((Bool) -> Void)?
    ) {
        readinessGeneration += 1
        let generation = readinessGeneration
        let deadline = Date().addingTimeInterval(ReadinessTiming.timeout)

        func poll() {
            guard generation == readinessGeneration, proxyProcess === process else { return }

            probeReadiness { [weak self] isReady in
                guard let self, generation == self.readinessGeneration, self.proxyProcess === process else {
                    return
                }

                if isReady {
                    self.state = .running
                    self.lastError = nil
                    NSLog("[CursorAgentProxy] Local proxy is serving requests on port %d", Self.proxyPort)
                    completion?(true)
                    return
                }

                guard Date() < deadline else {
                    NSLog("[CursorAgentProxy] Local proxy did not become ready within %.0fs", ReadinessTiming.timeout)
                    let detail = transcript.lastMeaningfulLine()
                    self.stopProxy()
                    self.fail(with: .neverBecameReady(detail))
                    completion?(false)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + ReadinessTiming.pollInterval, execute: poll)
            }
        }

        poll()
    }

    private func probeReadiness(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(Self.proxyBaseURL)/healthz") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = ReadinessTiming.probeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion(status == 200 || status == 204) }
        }.resume()
    }

    private func fail(with error: CursorAgentProxyError) {
        let description = error.localizedDescription
        lastError = description
        state = .failed(description)
        NSLog("[CursorAgentProxy] %@", description)
    }

    // MARK: - Agent CLI

    static func agentExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/cursor-agent").path,
            home.appendingPathComponent(".local/bin/agent").path,
            "/opt/homebrew/bin/cursor-agent",
            "/opt/homebrew/bin/agent",
            "/usr/local/bin/cursor-agent",
            "/usr/local/bin/agent"
        ]
        candidates.append(
            contentsOf: (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .flatMap { ["\($0)/cursor-agent", "\($0)/agent"] }
        )

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func currentLoginEmail() -> String? {
        guard let agentURL = agentExecutableURL() else { return nil }
        let process = Process()
        process.executableURL = agentURL
        process.arguments = ["status", "--format", "json"]
        process.environment = agentProbeEnvironment(agentURL: agentURL)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let authenticated = (json["isAuthenticated"] as? Bool) ?? ((json["status"] as? String) == "authenticated")
        guard authenticated else { return nil }
        if let email = (json["userInfo"] as? [String: Any])?["email"] as? String, !email.isEmpty {
            return email
        }
        if let email = json["email"] as? String, !email.isEmpty {
            return email
        }
        return "cursor-cli"
    }

    static func runAgentLogin(completion: @escaping (Bool, String) -> Void) {
        guard let agentURL = agentExecutableURL() else {
            completion(false, CursorAgentProxyError.agentNotInstalled.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = agentURL
            process.arguments = ["login"]
            process.environment = agentProbeEnvironment(agentURL: agentURL)
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
                return
            }
            let output = [
                String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            let success = process.terminationStatus == 0 && currentLoginEmail() != nil
            DispatchQueue.main.async {
                completion(success, output)
            }
        }
    }

    // MARK: - Node / PATH

    private static func npxExecutableURL() -> URL? {
        let fileManager = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            "/usr/bin/npx"
        ]
        candidates.append(
            contentsOf: (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map { "\($0)/npx" }
        )
        candidates.append(contentsOf: nodeVersionManagerBinDirectories().map { "\($0)/npx" })

        var seen = Set<String>()
        let executables = candidates.filter {
            seen.insert($0).inserted && fileManager.isExecutableFile(atPath: $0)
        }
        let preferred = executables.first {
            let binDirectory = URL(fileURLWithPath: $0).deletingLastPathComponent().path
            return fileManager.isExecutableFile(atPath: "\(binDirectory)/node")
        }
        guard let path = preferred ?? executables.first else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func nodeVersionManagerBinDirectories() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let versionRoots = [
            home.appendingPathComponent(".nvm/versions/node"),
            home.appendingPathComponent(".local/share/fnm/node-versions"),
            home.appendingPathComponent("Library/Application Support/fnm/node-versions"),
            home.appendingPathComponent(".volta/tools/image/node"),
            home.appendingPathComponent(".local/share/mise/installs/node")
        ]

        var directories: [String] = []
        if fileManager.isExecutableFile(atPath: home.appendingPathComponent(".local/share/mise/shims/npx").path) {
            directories.append(home.appendingPathComponent(".local/share/mise/shims").path)
        }
        directories.append(contentsOf: versionRoots.flatMap { root -> [String] in
            let versions = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .flatMap { version in
                    [
                        root.appendingPathComponent(version).appendingPathComponent("bin").path,
                        root.appendingPathComponent(version)
                            .appendingPathComponent("installation")
                            .appendingPathComponent("bin").path
                    ]
                }
        })
        return directories
    }

    private static func proxyEnvironment(npxURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CURSOR_BRIDGE_HOST"] = proxyHost
        environment["CURSOR_BRIDGE_PORT"] = String(proxyPort)
        // Chat-only uses a temp cwd + `--trust` so the CLI cannot read/write
        // the user's project. Point `CURSOR_CONFIG_DIRS` at the real
        // `~/.cursor` so the proxy does **not** fake `HOME` (that makes
        // `agent login` fail). ACP is off: `agent acp` exited 1 here;
        // `agent --print` is the working path. Stdin keeps large Droid
        // prompts off argv.
        environment["CURSOR_BRIDGE_CHAT_ONLY_WORKSPACE"] = "true"
        environment["CURSOR_BRIDGE_MODE"] = "ask"
        environment["CURSOR_BRIDGE_USE_ACP"] = "false"
        environment["CURSOR_BRIDGE_PROMPT_VIA_STDIN"] = "true"
        environment["CURSOR_BRIDGE_STRICT_MODEL"] = "true"
        environment["CURSOR_BRIDGE_CONTEXT_PREAMBLE"] = "false"
        environment["CURSOR_CONFIG_DIRS"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor").path
        environment["NO_UPDATE_NOTIFIER"] = "true"
        environment.removeValue(forKey: "CURSOR_BRIDGE_API_KEY")
        environment.removeValue(forKey: "CURSOR_BRIDGE_ACP_SKIP_AUTHENTICATE")

        if let agentURL = agentExecutableURL() {
            environment["CURSOR_AGENT_BIN"] = agentURL.path
        }

        let nodeBin = npxURL.deletingLastPathComponent().path
        let homeBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin").path
        let remaining = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != nodeBin && $0 != homeBin }
        environment["PATH"] = ([nodeBin, homeBin] + remaining).joined(separator: ":")
        return environment
    }

    private static func agentProbeEnvironment(agentURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin").path
        let agentBin = agentURL.deletingLastPathComponent().path
        let remaining = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != homeBin && $0 != agentBin }
        environment["PATH"] = ([agentBin, homeBin] + remaining).joined(separator: ":")
        return environment
    }

    private func attachOutputPipes(
        to process: Process,
        onOutput: @escaping (String) -> Void
    ) -> [Pipe] {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        for pipe in [outputPipe, errorPipe] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                onOutput(text)
            }
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        return [outputPipe, errorPipe]
    }

    private func clearProxyOutputPipes() {
        for pipe in proxyOutputPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        proxyOutputPipes.removeAll()
    }

    private func isolateProcessGroup(for process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if setpgid(pid, pid) == 0 {
            isolatedProcessGroups.insert(pid)
        } else {
            NSLog("[CursorAgentProxy] Could not isolate process group for PID %d", pid)
        }
    }

    private func terminate(_ process: Process) {
        let pid = process.processIdentifier
        let processGroupID: pid_t? = isolatedProcessGroups.remove(pid)
        let descendants = processGroupID == nil ? descendantProcessIDs(of: pid) : []

        if let processGroupID {
            _ = kill(-processGroupID, SIGTERM)
        } else {
            signal(descendants, with: SIGTERM)
            if process.isRunning {
                process.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(ProcessTiming.gracefulTerminationTimeout)
        while isRunning(process, processGroupID: processGroupID, descendants: descendants), Date() < deadline {
            Thread.sleep(forTimeInterval: ProcessTiming.terminationPollInterval)
        }

        if isRunning(process, processGroupID: processGroupID, descendants: descendants) {
            if let processGroupID {
                _ = kill(-processGroupID, SIGKILL)
            } else {
                signal(descendants, with: SIGKILL)
                if process.isRunning {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
    }

    private func isRunning(
        _ process: Process,
        processGroupID: pid_t?,
        descendants: [pid_t]
    ) -> Bool {
        if let processGroupID {
            return kill(-processGroupID, 0) == 0
        }
        return process.isRunning || descendants.contains { kill($0, 0) == 0 }
    }

    private func descendantProcessIDs(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }
        let directChildren = text
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0)) }
        return directChildren + directChildren.flatMap(descendantProcessIDs)
    }

    private func signal(_ pids: [pid_t], with signal: Int32) {
        for pid in pids.reversed() {
            _ = kill(pid, signal)
        }
    }
}
