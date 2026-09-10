import AppKit
import Combine
import Foundation

/// A model exposed by the local Copilot API gateway. The gateway obtains this
/// catalog from the signed-in Copilot account, so policies and plan-specific
/// availability are respected instead of being hard-coded in DroidProxy.
struct CopilotModelDescriptor: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let maxOutputTokens: Int
    let maxContextLimit: Int?
    let supportsVision: Bool
    let reasoningEfforts: [String]

    init(
        id: String,
        displayName: String,
        maxOutputTokens: Int,
        maxContextLimit: Int?,
        supportsVision: Bool,
        reasoningEfforts: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.maxContextLimit = maxContextLimit
        self.supportsVision = supportsVision
        self.reasoningEfforts = reasoningEfforts
    }

    /// Produces a stable Factory custom-model ID suffix without assuming that
    /// Copilot model identifiers use only alphanumeric characters.
    var identifierSlug: String {
        let components = id.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }
        let collapsed = components.joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "model" : collapsed
    }
}

/// Persists the last account-specific model catalog and at most three chosen
/// models. Factory custom-model entries are generated only from this selection.
enum CopilotModelPreferences {
    static let selectedModelIDsKey = "copilotSelectedModelIDs"
    static let cachedModelsKey = "copilotCachedModels"
    static let maximumSelectedModels = 3

    static var selectedModelIDs: [String] {
        normalizedModelIDs(UserDefaults.standard.stringArray(forKey: selectedModelIDsKey) ?? [])
    }

    static var cachedModels: [CopilotModelDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: cachedModelsKey),
              let models = try? JSONDecoder().decode([CopilotModelDescriptor].self, from: data) else {
            return []
        }
        return models
    }

    static var selectedModels: [CopilotModelDescriptor] {
        let cachedByID = Dictionary(uniqueKeysWithValues: cachedModels.map { ($0.id, $0) })
        return selectedModelIDs.map { id in
            cachedByID[id] ?? CopilotModelDescriptor(
                id: id,
                displayName: id,
                maxOutputTokens: 128_000,
                maxContextLimit: nil,
                supportsVision: false,
                reasoningEfforts: []
            )
        }
    }

    static func saveSelectedModelIDs(_ ids: [String]) {
        UserDefaults.standard.set(normalizedModelIDs(ids), forKey: selectedModelIDsKey)
    }

    static func saveCachedModels(_ models: [CopilotModelDescriptor]) {
        guard let data = try? JSONEncoder().encode(models) else {
            NSLog("[Copilot] Failed to encode cached model catalog")
            return
        }
        UserDefaults.standard.set(data, forKey: cachedModelsKey)
    }

    static func normalizedModelIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
        .prefix(maximumSelectedModels)
        .map { $0 }
    }
}

/// Lifecycle of the local Copilot gateway child process. A dedicated `failed`
/// case exists because `Process.run()` returning without throwing only means the
/// executable was spawned; the gateway can still exit before it binds its port,
/// and that outcome has to be distinguishable from a start still in flight.
enum CopilotGatewayState: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var failureDescription: String? {
        guard case .failed(let detail) = self else { return nil }
        return detail
    }
}

enum CopilotGatewayError: LocalizedError {
    case nodeNotInstalled
    case notAuthenticated
    case gatewayNotRunning
    case failedToStart(String)
    case stoppedUnexpectedly(String)
    case neverBecameReady(String?)
    case authenticationFailed(String?)
    case invalidModelResponse
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .nodeNotInstalled:
            return "Node.js 20 or later is required for GitHub Copilot support. Install Node.js, then try again."
        case .notAuthenticated:
            return "Connect GitHub Copilot before starting the local Copilot gateway."
        case .gatewayNotRunning:
            return "The local Copilot gateway is not running. Start it, then refresh models."
        case .failedToStart(let detail):
            return "Could not start the local Copilot gateway: \(detail)"
        case .stoppedUnexpectedly(let detail):
            return "The local Copilot gateway stopped unexpectedly: \(detail)"
        case .neverBecameReady(let detail):
            guard let detail, !detail.isEmpty else {
                return "The local Copilot gateway never started serving requests on port \(CopilotGatewayManager.gatewayPort)."
            }
            return "The local Copilot gateway never started serving requests on port \(CopilotGatewayManager.gatewayPort): \(detail)"
        case .authenticationFailed(let detail):
            guard let detail, !detail.isEmpty else {
                return "GitHub Copilot authentication did not complete. Please try again."
            }
            return "GitHub Copilot authentication did not complete: \(detail)"
        case .invalidModelResponse:
            return "The Copilot gateway returned an invalid model catalog."
        case .requestFailed:
            return "Could not load models from the local Copilot gateway."
        }
    }
}

/// Manages the independently packaged Copilot gateway. Mainline CLIProxyAPI
/// does not implement GitHub Copilot, so DroidProxy launches the maintained
/// `@jeffreycao/copilot-api` gateway on a localhost-only port.
final class CopilotGatewayManager: ObservableObject {
    static let gatewayPort = 8319
    static let gatewayBaseURL = "http://127.0.0.1:\(gatewayPort)/v1"
    static let packageSpecifier = "@jeffreycao/copilot-api@2.1.0"
    private static let factoryReasoningEffortOrder = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max"
    ]
    private static let factoryReasoningEfforts = Set(factoryReasoningEffortOrder)
    private static let supportedGatewayEndpoints: Set<String> = [
        "/chat/completions", "/responses", "ws:/responses", "/v1/messages"
    ]

    private enum ProcessTiming {
        static let gracefulTerminationTimeout: TimeInterval = 2.0
        static let terminationPollInterval: TimeInterval = 0.05
    }

    /// The first run of a given package version downloads it through `npx`, so
    /// the readiness window has to tolerate a cold npm cache.
    private enum ReadinessTiming {
        static let timeout: TimeInterval = 90
        static let pollInterval: TimeInterval = 0.5
        static let probeTimeout: TimeInterval = 3
    }

    static let dataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".droidproxy")
        .appendingPathComponent("copilot-api")
    static let credentialsURL = dataDirectory.appendingPathComponent("github_token")

    @Published private(set) var state: CopilotGatewayState = .idle
    @Published private(set) var isAuthenticating = false
    @Published private(set) var availableModels: [CopilotModelDescriptor]
    @Published private(set) var lastError: String?

    private var gatewayProcess: Process?
    private var authenticationProcess: Process?
    private var gatewayOutputPipes: [Pipe] = []
    private var authenticationOutputPipes: [Pipe] = []
    private var isolatedProcessGroups = Set<pid_t>()
    private var gatewayTranscript: ProcessTranscript?
    private var readinessGeneration = 0

    init() {
        availableModels = CopilotModelPreferences.cachedModels
    }

    var isRunning: Bool {
        state == .running
    }

    var hasCredentials: Bool {
        Self.hasCredentials
    }

    static var hasCredentials: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: credentialsURL.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    func start(completion: ((Bool) -> Void)? = nil) {
        if let gatewayProcess, gatewayProcess.isRunning, state == .running || state == .starting {
            completion?(state == .running)
            return
        }

        guard hasCredentials else {
            fail(with: .notAuthenticated)
            completion?(false)
            return
        }

        guard let npxURL = Self.npxExecutableURL() else {
            fail(with: .nodeNotInstalled)
            completion?(false)
            return
        }

        let process = Process()
        process.executableURL = npxURL
        process.arguments = [
            "--yes",
            Self.packageSpecifier,
            "--api-home=\(Self.dataDirectory.path)",
            "start",
            "--port",
            String(Self.gatewayPort)
        ]
        process.environment = Self.gatewayEnvironment(npxURL: npxURL)

        let transcript = ProcessTranscript()
        gatewayTranscript = transcript
        gatewayOutputPipes = attachOutputPipes(to: process) { text in
            transcript.append(text)
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            DispatchQueue.main.async {
                guard let self, self.gatewayProcess === process else { return }
                self.gatewayProcess = nil
                self.clearGatewayOutputPipes()
                // Supersede any in-flight readiness poll so it cannot overwrite
                // this exit with a stale timeout message.
                self.readinessGeneration += 1
                let detail = transcript.failureDetail(exitCode: terminatedProcess.terminationStatus)
                self.gatewayTranscript = nil
                NSLog("[Copilot] Local gateway exited (status %d): %@",
                      terminatedProcess.terminationStatus, detail ?? "no output")
                self.fail(with: .stoppedUnexpectedly(detail ?? "exit code \(terminatedProcess.terminationStatus)"))
            }
        }

        do {
            try process.run()
            isolateProcessGroup(for: process)
            gatewayProcess = process
            state = .starting
            lastError = nil
            NSLog("[Copilot] Launched local gateway on port %d, waiting for readiness", Self.gatewayPort)
            waitForReadiness(of: process, transcript: transcript, completion: completion)
        } catch {
            clearGatewayOutputPipes()
            gatewayTranscript = nil
            fail(with: .failedToStart(error.localizedDescription))
            completion?(false)
        }
    }

    func stop() {
        stopGateway()
        state = .idle
        lastError = nil
        cancelAuthentication()
    }

    /// Tears down the gateway child process without touching authentication or
    /// publishing a state, so callers can decide whether the outcome is a
    /// deliberate stop or a failure.
    private func stopGateway() {
        // Bump first so the termination handler's failure path and any pending
        // readiness poll are both treated as superseded by this teardown.
        readinessGeneration += 1
        if let gatewayProcess {
            gatewayProcess.terminationHandler = nil
            terminate(gatewayProcess)
        }
        gatewayProcess = nil
        gatewayTranscript = nil
        clearGatewayOutputPipes()
    }

    /// Polls the gateway's own `/models` endpoint until it answers, because a
    /// successfully spawned `npx` says nothing about whether the gateway bound
    /// its port. Without this, a gateway that exits early (for example when
    /// node is missing from the child's PATH) is indistinguishable from one
    /// that is still booting.
    private func waitForReadiness(
        of process: Process,
        transcript: ProcessTranscript,
        completion: ((Bool) -> Void)?
    ) {
        readinessGeneration += 1
        let generation = readinessGeneration
        let deadline = Date().addingTimeInterval(ReadinessTiming.timeout)

        func poll() {
            guard generation == readinessGeneration, gatewayProcess === process else { return }

            probeReadiness { [weak self] isReady in
                guard let self, generation == self.readinessGeneration, self.gatewayProcess === process else {
                    return
                }

                if isReady {
                    self.state = .running
                    self.lastError = nil
                    NSLog("[Copilot] Local gateway is serving requests on port %d", Self.gatewayPort)
                    completion?(true)
                    return
                }

                guard Date() < deadline else {
                    NSLog("[Copilot] Local gateway did not become ready within %.0fs", ReadinessTiming.timeout)
                    let detail = transcript.lastMeaningfulLine()
                    self.stopGateway()
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
        guard let url = URL(string: "\(Self.gatewayBaseURL)/models") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = ReadinessTiming.probeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let isReady = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(isReady) }
        }.resume()
    }

    private func fail(with error: CopilotGatewayError) {
        let description = error.localizedDescription
        state = .failed(description)
        lastError = description
    }

    func cancelAuthentication() {
        guard let authenticationProcess else { return }
        terminate(authenticationProcess)
        self.authenticationProcess = nil
        isAuthenticating = false
        clearAuthenticationOutputPipes()
    }

    /// Starts Copilot's device-code flow. The gateway owns the token file and
    /// keeps it mode 0600; DroidProxy never reads or logs its contents.
    func startAuthentication(
        onDeviceCode: @escaping (_ code: String, _ verificationURL: URL) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isAuthenticating else { return }
        guard let npxURL = Self.npxExecutableURL() else {
            completion(.failure(CopilotGatewayError.nodeNotInstalled))
            return
        }

        let process = Process()
        process.executableURL = npxURL
        process.arguments = [
            "--yes",
            Self.packageSpecifier,
            "--api-home=\(Self.dataDirectory.path)",
            "auth",
            "login",
            "--provider",
            "copilot"
        ]
        process.environment = Self.gatewayEnvironment(npxURL: npxURL)

        let promptCapture = DeviceCodeCapture(onDeviceCode: onDeviceCode)
        let transcript = ProcessTranscript()
        authenticationOutputPipes = attachOutputPipes(to: process) { text in
            transcript.append(text)
            promptCapture.append(text)
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            DispatchQueue.main.async {
                guard self?.authenticationProcess === process else { return }
                self?.authenticationProcess = nil
                self?.isAuthenticating = false
                self?.clearAuthenticationOutputPipes()
                if terminatedProcess.terminationStatus == 0, Self.hasCredentials {
                    self?.lastError = nil
                    NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
                    completion(.success(()))
                } else {
                    let detail = transcript.failureDetail(exitCode: terminatedProcess.terminationStatus)
                    NSLog("[Copilot] Device authentication failed (exit %d): %@",
                          terminatedProcess.terminationStatus, detail ?? "no output")
                    let error = CopilotGatewayError.authenticationFailed(detail)
                    self?.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }

        do {
            try process.run()
            isolateProcessGroup(for: process)
            authenticationProcess = process
            isAuthenticating = true
            lastError = nil
            NSLog("[Copilot] Started GitHub device authentication")
        } catch {
            clearAuthenticationOutputPipes()
            completion(.failure(CopilotGatewayError.failedToStart(error.localizedDescription)))
        }
    }

    func refreshAvailableModels(completion: @escaping (Result<[CopilotModelDescriptor], Error>) -> Void) {
        guard isRunning else {
            completion(.failure(CopilotGatewayError.gatewayNotRunning))
            return
        }

        guard let url = URL(string: "\(Self.gatewayBaseURL)/models") else {
            completion(.failure(CopilotGatewayError.requestFailed))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<[CopilotModelDescriptor], Error>
            if error != nil {
                result = .failure(CopilotGatewayError.requestFailed)
            } else if (response as? HTTPURLResponse)?.statusCode != 200 {
                result = .failure(CopilotGatewayError.requestFailed)
            } else if let data, let models = Self.parseModels(from: data) {
                result = .success(models)
            } else {
                result = .failure(CopilotGatewayError.invalidModelResponse)
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let models):
                    self?.availableModels = models
                    self?.lastError = nil
                    CopilotModelPreferences.saveCachedModels(models)
                    completion(.success(models))
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    @discardableResult
    func disconnect() -> Bool {
        stop()
        do {
            try FileManager.default.removeItem(at: Self.credentialsURL)
            clearCachedModelCatalog()
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            return true
        } catch CocoaError.fileNoSuchFile {
            clearCachedModelCatalog()
            return true
        } catch {
            lastError = "Could not remove GitHub Copilot credentials."
            return false
        }
    }

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

        // npx is a `#!/usr/bin/env node` script, so prefer an install whose own
        // bin directory also ships node; that directory is what makes the
        // shebang resolvable from the app's minimal PATH.
        let preferred = executables.first {
            let binDirectory = URL(fileURLWithPath: $0).deletingLastPathComponent().path
            return fileManager.isExecutableFile(atPath: "\(binDirectory)/node")
        }
        guard let path = preferred ?? executables.first else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Bin directories for the common per-user Node version managers. These are
    /// never on a Finder-launched app's PATH, so they have to be probed directly.
    private static func nodeVersionManagerBinDirectories() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let versionRoots = [
            home.appendingPathComponent(".nvm/versions/node"),
            home.appendingPathComponent(".local/share/fnm/node-versions"),
            home.appendingPathComponent("Library/Application Support/fnm/node-versions"),
            home.appendingPathComponent(".volta/tools/image/node")
        ]

        return versionRoots.flatMap { root -> [String] in
            let versions = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .flatMap { version in
                    // fnm nests the install one level deeper than nvm/volta.
                    [
                        root.appendingPathComponent(version).appendingPathComponent("bin").path,
                        root.appendingPathComponent(version)
                            .appendingPathComponent("installation")
                            .appendingPathComponent("bin").path
                    ]
                }
        }
    }

    /// A Finder-launched app inherits only `/usr/bin:/bin:/usr/sbin:/sbin`, which
    /// does not contain node. Without node's bin directory on PATH, npx's
    /// `#!/usr/bin/env node` shebang exits 127 before the CLI ever runs.
    private static func gatewayEnvironment(npxURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOST"] = "127.0.0.1"
        environment["NO_UPDATE_NOTIFIER"] = "true"

        // Prepend unconditionally: an earlier PATH entry holding a different node
        // would otherwise win the shebang lookup and pair the wrong runtime with
        // the npx that was chosen.
        let binDirectory = npxURL.deletingLastPathComponent().path
        let remainingEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .filter { $0 != binDirectory }
        environment["PATH"] = ([binDirectory] + remainingEntries.map(String.init))
            .joined(separator: ":")
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

    private func clearGatewayOutputPipes() {
        clearOutputPipes(&gatewayOutputPipes)
    }

    private func clearAuthenticationOutputPipes() {
        clearOutputPipes(&authenticationOutputPipes)
    }

    private func clearOutputPipes(_ pipes: inout [Pipe]) {
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        pipes.removeAll()
    }

    private func clearCachedModelCatalog() {
        availableModels = []
        CopilotModelPreferences.saveCachedModels([])
    }

    private func isolateProcessGroup(for process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if setpgid(pid, pid) == 0 {
            isolatedProcessGroups.insert(pid)
        } else {
            NSLog("[Copilot] Could not isolate process group for PID %d", pid)
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

    static func parseModels(from data: Data) -> [CopilotModelDescriptor]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelEntries = root["data"] as? [[String: Any]] else {
            return nil
        }

        let models = modelEntries.compactMap { entry -> CopilotModelDescriptor? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            if let policy = entry["policy"] as? [String: Any],
               (policy["state"] as? String)?.lowercased() == "disabled" {
                return nil
            }
            if (entry["model_picker_enabled"] as? Bool) == false {
                return nil
            }

            let endpoints = entry["supported_endpoints"] as? [String] ?? []
            guard endpoints.isEmpty || !Self.supportedGatewayEndpoints.isDisjoint(with: Set(endpoints)) else {
                return nil
            }

            let capabilities = entry["capabilities"] as? [String: Any] ?? [:]
            if (capabilities["type"] as? String)?.lowercased() == "embeddings" {
                return nil
            }
            let limits = capabilities["limits"] as? [String: Any] ?? [:]
            let supports = capabilities["supports"] as? [String: Any] ?? [:]
            let maxOutputTokens = (limits["max_output_tokens"] as? NSNumber)?.intValue ?? 128_000
            let contextWindow = (limits["max_context_window_tokens"] as? NSNumber)?.intValue
            let supportedReasoningEfforts = Set(
                (supports["reasoning_effort"] as? [String] ?? [])
                    .filter { Self.factoryReasoningEfforts.contains($0) }
            )
            let reasoningEfforts = Self.factoryReasoningEffortOrder.filter {
                supportedReasoningEfforts.contains($0)
            }

            return CopilotModelDescriptor(
                id: id,
                displayName: (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? id,
                maxOutputTokens: maxOutputTokens > 0 ? maxOutputTokens : 128_000,
                maxContextLimit: contextWindow.flatMap { $0 > 0 ? $0 : nil },
                supportsVision: supports["vision"] as? Bool ?? false,
                reasoningEfforts: reasoningEfforts
            )
        }

        return models.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

/// Retains the tail of a child process's combined output so a non-zero exit can
/// be reported with the reason the CLI printed instead of a generic message.
final class ProcessTranscript {
    private static let maximumRetainedCharacters = 4_096
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        if buffer.count > Self.maximumRetainedCharacters {
            buffer = String(buffer.suffix(Self.maximumRetainedCharacters))
        }
    }

    func failureDetail(exitCode: Int32) -> String? {
        guard let lastLine = lastMeaningfulLine() else {
            return "the sign-in helper exited with code \(exitCode)."
        }
        return "\(lastLine) (exit code \(exitCode))"
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// The last non-blank line of output with ANSI escapes stripped, so a
    /// failure can be reported with the reason the child process printed.
    func lastMeaningfulLine() -> String? {
        lock.lock()
        let text = buffer
        lock.unlock()

        return text
            .replacingOccurrences(
                of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

final class DeviceCodeCapture {
    private let lock = NSLock()
    private let onDeviceCode: (_ code: String, _ verificationURL: URL) -> Void
    private var buffer = ""
    private var delivered = false

    init(onDeviceCode: @escaping (_ code: String, _ verificationURL: URL) -> Void) {
        self.onDeviceCode = onDeviceCode
    }

    func append(_ text: String) {
        lock.lock()
        buffer += text
        if buffer.count > 8_192 {
            buffer = String(buffer.suffix(8_192))
        }
        let prompt = Self.parsePrompt(in: buffer)
        let shouldDeliver = prompt != nil && !delivered
        if shouldDeliver {
            delivered = true
        }
        lock.unlock()

        guard shouldDeliver, let prompt else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(prompt.url)
            self.onDeviceCode(prompt.code, prompt.url)
        }
    }

    static func parsePrompt(in text: String) -> (code: String, url: URL)? {
        let plainText = text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let codeMarker = "Please enter the code \""
        if let codeStart = plainText.range(of: codeMarker)?.upperBound,
           let codeEnd = plainText[codeStart...].firstIndex(of: "\"") {
            let code = String(plainText[codeStart..<codeEnd])
            let afterCode = plainText[codeEnd...]
            if let urlStart = afterCode.range(of: " in ")?.upperBound {
                let urlText = afterCode[urlStart...]
                    .prefix { !$0.isWhitespace }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty, let url = URL(string: String(urlText)) {
                    return (code, url)
                }
            }
        }

        let fullRange = NSRange(plainText.startIndex..., in: plainText)
        guard let urlExpression = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#),
              let urlMatch = urlExpression.firstMatch(in: plainText, range: fullRange),
              let urlRange = Range(urlMatch.range, in: plainText),
              let url = URL(
                string: String(plainText[urlRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;!"))
              ),
              let codeExpression = try? NSRegularExpression(
                pattern: #"(?:device\s*)?code\s*(?:is|:|=)?\s*["']?([A-Z0-9]{4,}(?:-[A-Z0-9]{2,})*)"#,
                options: .caseInsensitive
              ),
              let codeMatch = codeExpression.firstMatch(in: plainText, range: fullRange),
              let codeRange = Range(codeMatch.range(at: 1), in: plainText) else {
            return nil
        }
        return (String(plainText[codeRange]), url)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
