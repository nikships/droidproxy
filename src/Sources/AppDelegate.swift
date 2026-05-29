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
    private let updaterController: SPUStandardUpdaterController
    private var authDirectoryMonitor: AuthDirectoryMonitor?
    private var themeObserver: NSObjectProtocol?

    private static let menuBarIconSize = NSSize(width: 18, height: 18)

    // Menu item tags used by `updateMenuBarStatus` to look up entries again.
    private enum MenuTag {
        static let startStop = 100
        static let copyURL = 102
        static let dashboard = 103
    }
    
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
        let serviceIconSize = NSSize(width: 20, height: 20)
        let iconsToPreload: [(name: String, size: NSSize)] = [
            ("icon-active.png", Self.menuBarIconSize),
            ("icon-inactive.png", Self.menuBarIconSize),
            ("icon-claude.png", serviceIconSize),
            ("icon-codex.png", serviceIconSize),
            ("icon-gemini.png", serviceIconSize)
        ]

        for (name, size) in iconsToPreload where IconCatalog.shared.image(named: name, resizedTo: size, template: true) == nil {
            NSLog("[IconPreload] Warning: Failed to preload icon '%@'", name)
        }
    }
    
    private func configureNotifications() {
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("[Notifications] Authorization failed: %@", error.localizedDescription)
            }
            if !granted {
                NSLog("[Notifications] Authorization not granted; notifications will be suppressed")
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
        updateStatusBarIcon(isRunning: false)

        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Server: Stopped", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())

        let startStopItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "")
        startStopItem.tag = MenuTag.startStop
        menu.addItem(startStopItem)

        menu.addItem(NSMenuItem.separator())

        let copyURLItem = NSMenuItem(title: "Copy Server URL", action: #selector(copyServerURL), keyEquivalent: "c")
        copyURLItem.isEnabled = false
        copyURLItem.tag = MenuTag.copyURL
        menu.addItem(copyURLItem)

        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.isEnabled = false
        dashboardItem.tag = MenuTag.dashboard
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "u")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// Updates the menu-bar icon to reflect the current running state, falling
    /// back to system symbols when bundled assets are unavailable.
    private func updateStatusBarIcon(isRunning: Bool) {
        guard let button = statusItem?.button else { return }
        let iconName = isRunning ? "icon-active.png" : "icon-inactive.png"
        let stateLabel = isRunning ? "active" : "inactive"

        if let icon = IconCatalog.shared.image(named: iconName, resizedTo: Self.menuBarIconSize, template: true) {
            button.image = icon
            return
        }

        let fallbackSymbol = isRunning ? "network" : "network.slash"
        let accessibilityLabel = isRunning ? "Running" : "Stopped"
        let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: accessibilityLabel)
        fallback?.isTemplate = true
        button.image = fallback
        NSLog("[MenuBar] Failed to load %@ icon; using fallback", stateLabel)
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
        themeObserver = NotificationCenter.default.addObserver(
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
        // Fully opaque: solid NSWindow so macOS doesn't composite the desktop
        // behind it regardless of SwiftUI layers.
        // Translucent: keep non-opaque so VisualEffectBlur can show the desktop
        // blur; SwiftUI layers control the visible opacity.
        let isOpaque = AppPreferences.backgroundOpacity >= 1.0
        window.isOpaque = isOpaque
        window.backgroundColor = isOpaque ? .black : .clear
        window.alphaValue = 1.0
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
        // Stop the thinking proxy first to stop accepting new requests,
        // then shut down the CLIProxyAPI backend.
        thinkingProxy.stop()
        serverManager.stop()
        updateMenuBarStatus()
    }

    /// Shut down both local servers if the backend is currently running. Safe
    /// to call from termination paths where state may already be torn down.
    private func stopServersIfRunning() {
        guard serverManager.isRunning else { return }
        thinkingProxy.stop()
        serverManager.stop()
    }

    @objc func copyServerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let host = AppPreferences.bindAddress
        let displayHost = (host == "0.0.0.0") ? "localhost" : host
        pasteboard.setString("http://\(displayHost):\(thinkingProxy.proxyPort)", forType: .string)
        showNotification(title: "Copied", body: "Server URL copied to clipboard")
    }

    @objc func openDashboard() {
        let host = AppPreferences.bindAddress
        let displayHost = (host == "0.0.0.0") ? "127.0.0.1" : host
        if let url = URL(string: "http://\(displayHost):8318/management.html") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func handleAuthDirectoryChanged() {
        NSLog("[AppDelegate] Auth directory changed notification received — refreshing settings")
        // Re-open the settings window if it's already onscreen so the user sees
        // the newly-discovered account.
        guard let window = settingsWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func updateMenuBarStatus() {
        let isRunning = serverManager.isRunning

        if let serverStatus = menu.item(at: 0) {
            serverStatus.title = isRunning ? "Server: Running (port \(thinkingProxy.proxyPort))" : "Server: Stopped"
        }
        menu.item(withTag: MenuTag.startStop)?.title = isRunning ? "Stop Server" : "Start Server"
        menu.item(withTag: MenuTag.copyURL)?.isEnabled = isRunning
        menu.item(withTag: MenuTag.dashboard)?.isEnabled = isRunning

        updateStatusBarIcon(isRunning: isRunning)
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

    @objc func quit() {
        // Stop servers and give cleanup a moment before actually terminating.
        stopServersIfRunning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .serverStatusChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .authDirectoryChanged, object: nil)
        removeThemeObserver()
        authDirectoryMonitor?.stop()
        authDirectoryMonitor = nil
        stopServersIfRunning()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopServersIfRunning()
        return .terminateNow
    }

    private func removeThemeObserver() {
        guard let themeObserver else { return }
        NotificationCenter.default.removeObserver(themeObserver)
        self.themeObserver = nil
    }
    
    // MARK: - Auth Directory Monitoring

    private func startMonitoringAuthDirectory() {
        authDirectoryMonitor = AuthDirectoryMonitor(debounceInterval: 0.5, logPrefix: "[AppDelegate]") {
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
        }
        authDirectoryMonitor?.start()
    }

    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let droidProxyThemeChanged = Notification.Name("DroidProxyThemeChanged")
}

extension AppDelegate {
    func windowDidClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        removeThemeObserver()
        settingsWindow = nil
    }
}
