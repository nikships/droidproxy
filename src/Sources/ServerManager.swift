import Foundation
import Combine
import AppKit

private struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    
    init(capacity: Int) {
        let safeCapacity = max(1, capacity)
        storage = Array(repeating: nil, count: safeCapacity)
    }
    
    mutating func append(_ element: Element) {
        let capacity = storage.count
        storage[tail] = element
        
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
        
        tail = (tail + 1) % capacity
    }
    
    func elements() -> [Element] {
        let capacity = storage.count
        guard count > 0 else { return [] }
        
        var result: [Element] = []
        result.reserveCapacity(count)
        
        for index in 0..<count {
            let storageIndex = (head + index) % capacity
            if let value = storage[storageIndex] {
                result.append(value)
            }
        }
        
        return result
    }
}

class ServerManager: ObservableObject {
    private var process: Process?
    @Published private(set) var isRunning = false
    private(set) var port = 8317

    /// Provider enabled states - when disabled, models are excluded via oauth-excluded-models
    @Published var enabledProviders: [String: Bool] = [:] {
        didSet {
            UserDefaults.standard.set(enabledProviders, forKey: "enabledProviders")
        }
    }

    private var logBuffer: RingBuffer<String>
    private let maxLogLines = 1000
    private let processQueue = DispatchQueue(label: "io.automaze.droidproxy.server-process", qos: .userInitiated)
    
    private enum Timing {
        static let readinessCheckDelay: TimeInterval = 1.0
        static let gracefulTerminationTimeout: TimeInterval = 2.0
        static let terminationPollInterval: TimeInterval = 0.05
    }
    
    var onLogUpdate: (([String]) -> Void)?

    /// OAuth provider keys used in config.yaml oauth-excluded-models
    static let oauthProviderKeys: [ServiceType: String] = [
        .claude: "claude",
        .codex: "codex",
        .antigravity: "antigravity",
        .kimi: "kimi",
        .cursor: "cursor"
    ]

    init() {
        logBuffer = RingBuffer(capacity: maxLogLines)
        if let saved = UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] {
            enabledProviders = saved
        }
    }

    /// Check if a provider is enabled (defaults to true if not set)
    func isProviderEnabled(_ serviceType: ServiceType) -> Bool {
        enabledProviders[serviceType.rawValue] ?? true
    }

    /// Set provider enabled state and regenerate config (hot reload - no restart needed)
    func setProviderEnabled(_ serviceType: ServiceType, enabled: Bool) {
        enabledProviders[serviceType.rawValue] = enabled
        addLog(enabled ? "✓ Enabled provider: \(serviceType.displayName)" : "⚠️ Disabled provider: \(serviceType.displayName)")

        // Regenerate config - CLIProxyAPI hot reloads config.yaml automatically
        _ = getConfigPath()
        addLog("Config updated (hot reload)")
    }
    
    deinit {
        // Ensure cleanup on deallocation
        stop()
        killOrphanedProcesses()
    }
    
    func start(completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }

        // Clean up any orphaned processes from previous crashes
        killOrphanedProcesses()

        guard let bundledPath = bundledBinaryPath() else {
            addLog("❌ Error: cli-proxy-api-plus binary not found in app bundle")
            completion(false)
            return
        }

        // Use config path (merged with user settings and provider exclusions)
        let configPath = getConfigPath()
        guard !configPath.isEmpty, FileManager.default.fileExists(atPath: configPath) else {
            addLog("❌ Error: config.yaml not found")
            completion(false)
            return
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bundledPath)
        proc.arguments = ["-config", configPath]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let output = String(data: handle.availableData, encoding: .utf8), !output.isEmpty else { return }
            self?.addLog(output)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let output = String(data: handle.availableData, encoding: .utf8), !output.isEmpty else { return }
            self?.addLog("⚠️ \(output)")
        }

        proc.terminationHandler = { [weak self] process in
            // Clear pipe handlers to prevent retain cycles on the file handles.
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                self?.isRunning = false
                self?.addLog("Server stopped with code: \(process.terminationStatus)")
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
            }
        }

        process = proc

        do {
            try proc.run()
            DispatchQueue.main.async { self.isRunning = true }
            addLog("✓ Server started on port \(port)")

            // Give the backend a moment to actually bind before reporting success.
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.readinessCheckDelay) { [weak self] in
                guard let self = self else { return }
                if let running = self.process, running.isRunning {
                    NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                    completion(true)
                } else {
                    self.addLog("⚠️ Server exited before becoming ready")
                    completion(false)
                }
            }
        } catch {
            addLog("❌ Failed to start server: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    func stop(completion: (() -> Void)? = nil) {
        guard let process = process else {
            DispatchQueue.main.async {
                self.isRunning = false
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion?()
            }
            return
        }
        
        let pid = process.processIdentifier
        addLog("Stopping server (PID: \(pid))...")
        processQueue.async { [weak self] in
            guard let self = self else { return }
            
            // First try graceful termination (SIGTERM)
            process.terminate()
            
            // Wait up to configured interval for graceful termination
            let deadline = Date().addingTimeInterval(Timing.gracefulTerminationTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: Timing.terminationPollInterval)
            }
            
            // If still running, force kill (SIGKILL)
            if process.isRunning {
                self.addLog("⚠️ Server didn't stop gracefully, force killing...")
                kill(pid, SIGKILL)
            }
            
            process.waitUntilExit()
            
            DispatchQueue.main.async {
                self.process = nil
                self.isRunning = false
                self.addLog("✓ Server stopped")
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion?()
            }
        }
    }
    
    func runAuthCommand(_ command: AuthCommand, completion: @escaping (Bool, String) -> Void) {
        guard let bundledPath = bundledBinaryPath(),
              let resourcePath = Bundle.main.resourcePath else {
            completion(false, "cli-proxy-api-plus binary not found in app bundle")
            return
        }

        // Auth flow uses the bundled (unmerged) config; user-specific overrides
        // aren't needed for OAuth login itself.
        let configPath = (resourcePath as NSString).appendingPathComponent("config.yaml")

        let authProcess = Process()
        authProcess.executableURL = URL(fileURLWithPath: bundledPath)
        authProcess.arguments = ["--config", configPath, command.loginFlag]
        authProcess.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        authProcess.standardOutput = outputPipe
        authProcess.standardError = errorPipe
        authProcess.standardInput = inputPipe

        // For Codex login, avoid blocking on the manual callback prompt after ~15s.
        if case .codexLogin = command {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 12.0) {
                guard authProcess.isRunning, let data = "\n".data(using: .utf8) else { return }
                try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                NSLog("[Auth] Sent newline to keep Codex login waiting for callback")
            }
        }

        let browserOpenedMessage = "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect when you're authenticated."

        do {
            NSLog("[Auth] Starting process: %@ with args: %@", bundledPath, authProcess.arguments?.joined(separator: " ") ?? "none")
            try authProcess.run()
            addLog("✓ Authentication process started (PID: \(authProcess.processIdentifier)) - browser should open shortly")
            NSLog("[Auth] Process started with PID: %d", authProcess.processIdentifier)

            // Notify watchers when auth completes successfully so the UI can pick
            // up the freshly written credential file.
            authProcess.terminationHandler = { process in
                NSLog("[Auth] Process terminated with exit code: %d", process.terminationStatus)
                guard process.terminationStatus == 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
                }
            }

            // Wait briefly to check if process crashes immediately
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                if authProcess.isRunning {
                    NSLog("[Auth] Process running after wait, returning success")
                    completion(true, browserOpenedMessage)
                    return
                }

                // Process died quickly - check stdout/stderr for clues.
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                NSLog("[Auth] Process died quickly - output: %@", output.isEmpty ? "(empty)" : String(output.prefix(200)))

                if output.contains("Opening browser") || output.contains("Attempting to open URL") {
                    // Browser opened but process finished — treat as success.
                    NSLog("[Auth] Browser opened, process completed")
                    completion(true, browserOpenedMessage)
                } else {
                    NSLog("[Auth] Process failed")
                    let message: String
                    if !error.isEmpty {
                        message = error
                    } else if !output.isEmpty {
                        message = output
                    } else {
                        message = "Authentication process failed unexpectedly"
                    }
                    completion(false, message)
                }
            }
        } catch {
            NSLog("[Auth] Failed to start: %@", error.localizedDescription)
            completion(false, "Failed to start auth process: \(error.localizedDescription)")
        }
    }

    /// Resolves the path to the bundled `cli-proxy-api-plus` binary, returning
    /// `nil` if the resource directory or binary is missing.
    private func bundledBinaryPath() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("cli-proxy-api-plus")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    
    private func addLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logLine = "[\(timestamp)] \(message)"
            
            self.logBuffer.append(logLine)
            self.onLogUpdate?(self.logBuffer.elements())
        }
    }
    
    /// Returns the config path to use, merging bundled config with user settings and provider exclusions.
    /// User settings (allow-remote, secret-key) are stored in UserDefaults so they persist across app updates.
    func getConfigPath() -> String {
        guard let resourcePath = Bundle.main.resourcePath else {
            return ""
        }

        let bundledConfigPath = (resourcePath as NSString).appendingPathComponent("config.yaml")
        let authDir = AuthPaths.authDirectory

        guard var configContent = try? String(contentsOfFile: bundledConfigPath, encoding: .utf8) else {
            return bundledConfigPath
        }

        // Inject user-persisted remote-management settings from UserDefaults
        let allowRemote = AppPreferences.allowRemote
        let secretKey = AppPreferences.secretKey
        let bindAddress = AppPreferences.bindAddress

        // bindAddress is user-controlled (already validated/sanitized in
        // AppPreferences). Replace only the first `host:` anchor rather than
        // every occurrence, and warn if the expected anchor is missing so
        // silent config drift is visible in the logs.
        if let hostRange = configContent.range(of: "host: 127.0.0.1") {
            configContent.replaceSubrange(hostRange, with: "host: \(bindAddress)")
        } else {
            NSLog("[ServerManager] Warning: 'host: 127.0.0.1' anchor not found in bundled config; bind address not applied")
        }
        configContent = configContent.replacingOccurrences(
            of: "  allow-remote: false",
            with: "  allow-remote: \(allowRemote)"
        )
        configContent = configContent.replacingOccurrences(
            of: "  secret-key: \"\"  # Leave empty to disable management API",
            with: "  secret-key: \"\(secretKey)\""
        )

        // Inject verbose-logging preference (controls both debug verbosity and file logging)
        let verboseLogging = AppPreferences.verboseLogging
        configContent = configContent.replacingOccurrences(
            of: "debug: false",
            with: "debug: \(verboseLogging)"
        )
        configContent = configContent.replacingOccurrences(
            of: "logging-to-file: false",
            with: "logging-to-file: \(verboseLogging)"
        )

        // Append provider exclusions for any provider toggled off in the UI.
        let disabledProviders = Self.oauthProviderKeys
            .filter { !isProviderEnabled($0.key) }
            .map { $0.value }
            .sorted()

        if !disabledProviders.isEmpty {
            configContent += "\n# Provider exclusions (auto-added by DroidProxy)\noauth-excluded-models:\n"
            for provider in disabledProviders {
                configContent += "  \(provider):\n    - \"*\"\n"
            }
        }

        let mergedConfigPath = authDir.appendingPathComponent("merged-config.yaml")

        do {
            try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
            try configContent.write(to: mergedConfigPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mergedConfigPath.path)
            return mergedConfigPath.path
        } catch {
            NSLog("[ServerManager] Failed to write merged config: %@", error.localizedDescription)
            return bundledConfigPath
        }
    }
    
    func getLogs() -> [String] {
        return logBuffer.elements()
    }
    
    /// Kill any orphaned cli-proxy-api-plus processes that might be running
    private func killOrphanedProcesses() {
        // First check if any processes exist using pgrep
        let checkTask = Process()
        checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkTask.arguments = ["-f", "cli-proxy-api-plus"]
        
        let outputPipe = Pipe()
        checkTask.standardOutput = outputPipe
        checkTask.standardError = Pipe() // Suppress errors
        
        do {
            try checkTask.run()
            checkTask.waitUntilExit()
            
            // If pgrep found processes (exit code 0), kill them
            if checkTask.terminationStatus == 0 {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let pids = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                
                if !pids.isEmpty {
                    addLog("⚠️ Found orphaned server process(es): \(pids.joined(separator: ", "))")
                    
                    // Now kill them
                    let killTask = Process()
                    killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                    killTask.arguments = ["-9", "-f", "cli-proxy-api-plus"]
                    
                    try killTask.run()
                    killTask.waitUntilExit()
                    
                    // Wait a moment for cleanup
                    Thread.sleep(forTimeInterval: 0.5)
                    addLog("✓ Cleaned up orphaned processes")
                }
            }
            // Exit code 1 means no processes found - this is fine, no need to log
        } catch {
            // Silently fail - this is not critical
        }
    }
}

enum AuthCommand: Equatable {
    case claudeLogin
    case codexLogin
    case antigravityLogin
    case kimiLogin

    /// CLI flag passed to `cli-proxy-api-plus` for this login flow.
    var loginFlag: String {
        switch self {
        case .claudeLogin: return "-claude-login"
        case .codexLogin: return "-codex-login"
        case .antigravityLogin: return "-antigravity-login"
        case .kimiLogin: return "-kimi-login"
        }
    }
}
