import Cocoa
import SwiftUI
import WebKit
import UserNotifications
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    weak var settingsWindow: NSWindow?
    var serverManager: ServerManager!
    var thinkingProxy: ThinkingProxy!
    private let notificationCenter = UNUserNotificationCenter.current()
    private var notificationPermissionGranted = false
    private let updaterController: SPUStandardUpdaterController
    private var authFileMonitor: DispatchSourceFileSystemObject?
    private var pendingAuthRefresh: DispatchWorkItem?
    
    override init() {
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Setup standard Edit menu for keyboard shortcuts (Cmd+C/V/X/A)
        setupMainMenu()
        
        // Setup menu bar
        setupMenuBar()

        // Initialize managers
        serverManager = ServerManager()
        thinkingProxy = ThinkingProxy()
        
        // Initialize UsageStore
        UsageStore.shared.start()

        // Warm commonly used icons to avoid first-use disk hits
        preloadIcons()
        
        configureNotifications()

        // Start server automatically
        startServer()

        // Register for notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarStatus),
            name: .serverStatusChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateUsageMenu),
            name: .usageUpdated,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Monitor auth directory for credential file changes (app-lifetime scope)
        startMonitoringAuthDirectory()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthDirectoryChanged),
            name: .authDirectoryChanged,
            object: nil
        )
    }
    
    private func preloadIcons() {
        let statusIconSize = NSSize(width: 18, height: 18)
        let serviceIconSize = NSSize(width: 20, height: 20)
        
        let iconsToPreload = [
            ("icon-active.png", statusIconSize),
            ("icon-inactive.png", statusIconSize),
            ("icon-claude.png", serviceIconSize),
            ("icon-codex.png", serviceIconSize),
            ("icon-gemini.png", serviceIconSize)
        ]
        
        for (name, size) in iconsToPreload {
            if IconCatalog.shared.image(named: name, resizedTo: size, template: true) == nil {
                NSLog("[IconPreload] Warning: Failed to preload icon '%@'", name)
            }
        }
    }
    
    private func configureNotifications() {
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                NSLog("[Notifications] Authorization failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                self?.notificationPermissionGranted = granted
                if !granted {
                    NSLog("[Notifications] Authorization not granted; notifications will be suppressed")
                }
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About DroidProxy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit DroidProxy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // Edit menu (for Cmd+C/V/X/A to work)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApplication.shared.mainMenu = mainMenu
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let icon = IconCatalog.shared.image(named: "icon-inactive.png", resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
            } else {
                let fallback = NSImage(systemSymbolName: "network.slash", accessibilityDescription: "DroidProxy")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load inactive icon from bundle; using fallback system icon")
            }
        }

        menu = NSMenu()

        // Server Status
        menu.addItem(NSMenuItem(title: "Server: Stopped", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Main Actions
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        
        // Usage
        let claudeUsageItem = NSMenuItem(title: "● Claude   --", action: nil, keyEquivalent: "")
        claudeUsageItem.tag = 200
        menu.addItem(claudeUsageItem)
        
        let codexUsageItem = NSMenuItem(title: "● Codex    --", action: nil, keyEquivalent: "")
        codexUsageItem.tag = 201
        menu.addItem(codexUsageItem)
        
        let refreshUsageItem = NSMenuItem(title: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r")
        refreshUsageItem.tag = 202
        menu.addItem(refreshUsageItem)
        
        let usageSeparator = NSMenuItem.separator()
        usageSeparator.tag = 203
        menu.addItem(usageSeparator)

        // Server Control
        let startStopItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "")
        startStopItem.tag = 100
        menu.addItem(startStopItem)

        menu.addItem(NSMenuItem.separator())

        // Copy URL
        let copyURLItem = NSMenuItem(title: "Copy Server URL", action: #selector(copyServerURL), keyEquivalent: "c")
        copyURLItem.isEnabled = false
        copyURLItem.tag = 102
        menu.addItem(copyURLItem)

        // Open Dashboard
        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.isEnabled = false
        dashboardItem.tag = 103
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        // Check for Updates
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "u")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }



    @objc func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func createSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DroidProxy"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        // Fully transparent titlebar so the traffic-light buttons float over the
        // Liquid Glass content. Content extends edge-to-edge under the title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // Alpha depends on theme: opaque OLED vs translucent Liquid Glass.
        applyTheme(to: window)

        // Listen for theme changes from SettingsView and update alphaValue live.
        NotificationCenter.default.addObserver(
            forName: .droidProxyThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let win = self?.settingsWindow else { return }
            self?.applyTheme(to: win)
        }

        let contentView = SettingsView(serverManager: serverManager)
        window.contentView = NSHostingView(rootView: contentView)

        settingsWindow = window
    }
    
    private func applyTheme(to window: NSWindow) {
        let opacity = AppPreferences.backgroundOpacity
        if opacity >= 1.0 {
            // Fully opaque: make the window a solid NSWindow so macOS doesn't
            // composite the desktop behind it regardless of SwiftUI layers.
            window.isOpaque = true
            window.backgroundColor = .black
            window.alphaValue = 1.0
        } else {
            // Translucent: keep non-opaque so VisualEffectBlur can show the
            // desktop blur. SwiftUI layers control the visible opacity.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.alphaValue = 1.0
        }
    }

    func windowDidClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }

    @objc func toggleServer() {
        if serverManager.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func startServer() {
        // Start the thinking proxy first (port 8317)
        thinkingProxy.start()
        
        // Poll for thinking proxy readiness with timeout
        pollForProxyReadiness(attempts: 0, maxAttempts: 60, intervalMs: 50)
    }
    
    private func pollForProxyReadiness(attempts: Int, maxAttempts: Int, intervalMs: Int) {
        // Check if proxy is running
        if thinkingProxy.isRunning {
            // Success - proceed to start backend
            serverManager.start { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.updateMenuBarStatus()
                        // User always connects to 8317 (thinking proxy)
                        self?.showNotification(title: "Server Started", body: "DroidProxy is now running")
                    } else {
                        // Backend failed - stop the proxy to keep state consistent
                        self?.thinkingProxy.stop()
                        self?.showNotification(title: "Server Failed", body: "Could not start backend server on port 8318")
                    }
                }
            }
            return
        }
        
        // Check if we've exceeded timeout
        if attempts >= maxAttempts {
            DispatchQueue.main.async { [weak self] in
                // Clean up partially initialized proxy
                self?.thinkingProxy.stop()
                self?.showNotification(title: "Server Failed", body: "Could not start thinking proxy on port 8317 (timeout)")
            }
            return
        }
        
        // Schedule next poll
        let interval = Double(intervalMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.pollForProxyReadiness(attempts: attempts + 1, maxAttempts: maxAttempts, intervalMs: intervalMs)
        }
    }

    func stopServer() {
        // Stop the thinking proxy first to stop accepting new requests
        thinkingProxy.stop()
        
        // Then stop CLIProxyAPI backend
        serverManager.stop()
        
        updateMenuBarStatus()
    }

    @objc func copyServerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://localhost:\(thinkingProxy.proxyPort)", forType: .string)
        showNotification(title: "Copied", body: "Server URL copied to clipboard")
    }

    @objc func openDashboard() {
        if let url = URL(string: "http://localhost:8318/management.html") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func handleAuthDirectoryChanged() {
        NSLog("[AppDelegate] Auth directory changed notification received — refreshing settings")
        // Re-open settings window if it exists so the user sees the new account
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func updateMenuBarStatus() {
        // Update status items
        if let serverStatus = menu.item(at: 0) {
            serverStatus.title = serverManager.isRunning ? "Server: Running (port \(thinkingProxy.proxyPort))" : "Server: Stopped"
        }

        // Update button states
        if let startStopItem = menu.item(withTag: 100) {
            startStopItem.title = serverManager.isRunning ? "Stop Server" : "Start Server"
        }

        if let copyURLItem = menu.item(withTag: 102) {
            copyURLItem.isEnabled = serverManager.isRunning
        }

        if let dashboardItem = menu.item(withTag: 103) {
            dashboardItem.isEnabled = serverManager.isRunning
        }

        // Update icon based on server status
        if let button = statusItem.button {
            let iconName = serverManager.isRunning ? "icon-active.png" : "icon-inactive.png"
            let fallbackSymbol = serverManager.isRunning ? "network" : "network.slash"
            
            if let icon = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
                NSLog("[MenuBar] Loaded %@ icon from cache", serverManager.isRunning ? "active" : "inactive")
            } else {
                let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: serverManager.isRunning ? "Running" : "Stopped")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load %@ icon; using fallback", serverManager.isRunning ? "active" : "inactive")
            }
        }
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "io.automaze.droidproxy.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                NSLog("[Notifications] Failed to deliver notification '%@': %@", title, error.localizedDescription)
            }
        }
    }

    @MainActor @objc func refreshUsage() {
        UsageStore.shared.refresh()
    }
    
    @MainActor @objc func handleWake() {
        UsageStore.shared.refresh()
    }
    
    @MainActor @objc func updateUsageMenu() {
        let showUsage = AppPreferences.showUsageInMenuBar
        
        menu.item(withTag: 200)?.isHidden = !showUsage
        menu.item(withTag: 201)?.isHidden = !showUsage
        menu.item(withTag: 202)?.isHidden = !showUsage
        menu.item(withTag: 203)?.isHidden = !showUsage
        
        if statusItem.button?.title != "" {
            statusItem.button?.title = ""
        }

        guard showUsage else { return }

        if let claudeItem = menu.item(withTag: 200) {
            if let snapshot = UsageStore.shared.claudeUsage {
                if let error = snapshot.error {
                    claudeItem.title = "● Claude   Error: \(error)"
                } else if snapshot.windows.isEmpty {
                    claudeItem.title = "● Claude   No usage data"
                } else {
                    let hourly = snapshot.windows.first { $0.kind == .other } // We mapped 5h to other
                    let weekly = snapshot.windows.first { $0.kind == .weekly }

                    var title = "● Claude"
                    if let h = hourly {
                        title += String(format: "   5h: %2d%%", Int(h.percentUsed))
                    }
                    if let w = weekly {
                        title += String(format: "   Week: %2d%%", Int(w.percentUsed))
                    }
                    if let h = hourly, let resetsAt = h.resetsAt {
                        let diff = Int(resetsAt.timeIntervalSinceNow / 3600)
                        title += "   (resets \(diff)h)"
                    }
                    claudeItem.title = title
                }
            } else {
                claudeItem.title = "● Claude   Loading..."
            }
        }

        if let codexItem = menu.item(withTag: 201) {
            if let snapshot = UsageStore.shared.codexUsage {
                if let error = snapshot.error {
                    codexItem.title = "● Codex    Error: \(error)"
                } else if snapshot.windows.isEmpty {
                    codexItem.title = "● Codex    No usage data"
                } else {
                    let hourly = snapshot.windows.first { $0.kind == .other }
                    let weekly = snapshot.windows.first { $0.kind == .weekly }

                    var title = "● Codex"
                    if let h = hourly {
                        title += String(format: "    5h: %2d%%", Int(h.percentUsed))
                    }
                    if let w = weekly {
                        title += String(format: "   Week: %2d%%", Int(w.percentUsed))
                    }
                    if let h = hourly, let resetsAt = h.resetsAt {
                        let diff = Int(resetsAt.timeIntervalSinceNow / 3600)
                        title += "   (resets \(diff)h)"
                    }
                    codexItem.title = title
                }
            } else {
                codexItem.title = "● Codex    Loading..."
            }
        }
    }

    @objc func quit() {
        // Stop server and wait for cleanup before quitting
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        }
        // Give a moment for cleanup to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .serverStatusChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .authDirectoryChanged, object: nil)
        pendingAuthRefresh?.cancel()
        authFileMonitor?.cancel()
        authFileMonitor = nil
        // Final cleanup - stop server if still running
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If server is running, stop it first
        if serverManager.isRunning {
            thinkingProxy.stop()
            serverManager.stop()
            // Give server time to stop (up to 3 seconds total with the improved stop method)
            return .terminateNow
        }
        return .terminateNow
    }
    
    // MARK: - Auth Directory Monitoring

    private func startMonitoringAuthDirectory() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

        let fileDescriptor = open(authDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.pendingAuthRefresh?.cancel()
            let workItem = DispatchWorkItem {
                NSLog("[AppDelegate] Auth directory changed — posting notification")
                NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            }
            self?.pendingAuthRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        authFileMonitor = source
    }

    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let droidProxyThemeChanged = Notification.Name("DroidProxyThemeChanged")
}
