import SwiftUI
import ServiceManagement
import AppKit

// MARK: - NSVisualEffectView bridge for live backdrop blur behind the window
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Liquid Glass helpers (macOS 26+)
// These wrap the new Liquid Glass APIs with availability fallbacks so the
// settings UI keeps its current look on older macOS versions.

extension View {
    /// Applies a Liquid Glass card background on macOS 26+, falling back to a
    /// flat rounded-rect fill on older systems.
    @ViewBuilder
    func droidGlassCard(cornerRadius: CGFloat = 14, tint: Color? = nil, fallback: Color = Color(red: 0x12/255, green: 0x12/255, blue: 0x12/255)) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(fallback)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Applies an interactive Liquid Glass capsule on macOS 26+, else a rounded background.
    @ViewBuilder
    func droidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            switch (tint, interactive) {
            case (let t?, true):  self.glassEffect(.regular.tint(t).interactive(), in: .capsule)
            case (let t?, false): self.glassEffect(.regular.tint(t), in: .capsule)
            case (nil, true):     self.glassEffect(.regular.interactive(), in: .capsule)
            case (nil, false):    self.glassEffect(.regular, in: .capsule)
            }
        } else {
            self
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    /// Applies a prominent Liquid Glass button style on macOS 26+, else plain.
    @ViewBuilder
    func droidGlassProminent() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func droidGlassPlain() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// A single account row with disable toggle and remove button
struct AccountRowView: View {
    static let accent = Color(red: 0xF2/255, green: 0x7B/255, blue: 0x2F/255)
    
    let account: AuthAccount
    let removeColor: Color
    let showDisableToggle: Bool
    let isLastEnabled: Bool
    let onToggleDisabled: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isDisabled ? Color.gray : (account.isExpired ? Self.accent.opacity(0.6) : Self.accent))
                .frame(width: 6, height: 6)
            Text(account.displayName)
                .font(.caption)
                .foregroundColor(account.isDisabled ? .secondary.opacity(0.5) : (account.isExpired ? Self.accent.opacity(0.6) : .secondary))
                .strikethrough(account.isDisabled)
            if account.isExpired && !account.isDisabled {
                Text("(expired)")
                    .font(.caption2)
                    .foregroundColor(Self.accent.opacity(0.6))
            }
            if account.isDisabled {
                Text("(disabled)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if showDisableToggle {
                let canDisable = account.isDisabled || !isLastEnabled
                Button(action: onToggleDisabled) {
                    Text(account.isDisabled ? "Enable" : "Disable")
                        .font(.caption)
                        .foregroundColor(account.isDisabled ? Self.accent : (canDisable ? Self.accent.opacity(0.6) : .secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canDisable)
                .help(!canDisable ? "At least one account must remain enabled" : "")
                .onHover { inside in
                    if canDisable {
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
            Button(action: onRemove) {
                HStack(spacing: 2) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                    Text("Remove")
                        .font(.caption)
                }
                .foregroundColor(removeColor)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.leading, 28)
    }
}

/// A row displaying a service with its connected accounts and add button
struct ServiceRow<ExtraContent: View>: View {
    let serviceType: ServiceType
    let iconName: String
    let accounts: [AuthAccount]
    let isAuthenticating: Bool
    let helpText: String?
    let isEnabled: Bool
    let customTitle: String?
    let onConnect: () -> Void
    let onDisconnect: (AuthAccount) -> Void
    let onToggleDisabled: (AuthAccount) -> Void
    let onToggleEnabled: (Bool) -> Void
    let toggleTint: Color
    var onExpandChange: ((Bool) -> Void)? = nil
    @ViewBuilder var extraContent: () -> ExtraContent

    @State private var isExpanded = false
    @State private var accountToRemove: AuthAccount?
    @State private var showingRemoveConfirmation = false

    private let removeColor = Color(red: 0xeb/255, green: 0x0f/255, blue: 0x0f/255)
    
    private var displayTitle: String {
        customTitle ?? serviceType.displayName
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row
            HStack {
                // Enable/disable toggle
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggleEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(toggleTint)
                .labelsHidden()
                .help(isEnabled ? "Disable this provider" : "Enable this provider")

                if let nsImage = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 20, height: 20), template: true) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                        .opacity(isEnabled ? 1.0 : 0.4)
                }
                Text(displayTitle)
                    .fontWeight(.medium)
                    .foregroundColor(isEnabled ? .primary : .secondary)
                Spacer()
                if isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else if isEnabled {
                    Button("Add Account") {
                        onConnect()
                    }
                    .droidGlassProminent()
                    .tint(toggleTint)
                    .controlSize(.small)
                }
            }
            
            // Account display (only shown when enabled)
            if isEnabled {
                let enabledCount = accounts.filter { !$0.isDisabled }.count
                if !accounts.isEmpty {
                    // Collapsible summary
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(accounts.count) connected account\(accounts.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(AccountRowView.accent)

                            if enabledCount > 1 {
                                Text("• Round-robin w/ auto-failover")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .droidGlassCapsule(tint: AccountRowView.accent.opacity(0.18), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                    .accessibilityLabel("\(accounts.count) connected \(accounts.count == 1 ? "account" : "accounts")")
                    .accessibilityHint(isExpanded ? "Collapse account list" : "Expand account list")

                    // Expanded accounts list
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(accounts) { account in
                                AccountRowView(account: account, removeColor: removeColor, showDisableToggle: accounts.count > 1, isLastEnabled: !account.isDisabled && enabledCount <= 1, onToggleDisabled: {
                                    onToggleDisabled(account)
                                }) {
                                    accountToRemove = account
                                    showingRemoveConfirmation = true
                                }
                            }
                            extraContent()
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text("No connected accounts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 4)
        .help(helpText ?? "")
        .onAppear {
            if accounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: accounts) { newAccounts in
            if newAccounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: isExpanded) { newValue in
            onExpandChange?(newValue)
        }
        .alert("Remove Account", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {
                accountToRemove = nil
            }
            Button("Remove", role: .destructive) {
                if let account = accountToRemove {
                    onDisconnect(account)
                }
                accountToRemove = nil
            }
        } message: {
            if let account = accountToRemove {
                Text("Are you sure you want to remove \(account.displayName) from \(serviceType.displayName)?")
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var serverManager: ServerManager
    @StateObject private var authManager = AuthManager()
    @StateObject private var oauthUsageTracker = OAuthUsageTracker()
    @State private var launchAtLogin = false
    @AppStorage(AppPreferences.gpt52FastModeKey) private var gpt52FastMode = AppPreferences.defaultGpt52FastMode
    @AppStorage(AppPreferences.gpt53CodexFastModeKey) private var gpt53CodexFastMode = AppPreferences.defaultGpt53CodexFastMode
    @AppStorage(AppPreferences.gpt54FastModeKey) private var gpt54FastMode = AppPreferences.defaultGpt54FastMode
    @AppStorage(AppPreferences.gpt55FastModeKey) private var gpt55FastMode = AppPreferences.defaultGpt55FastMode
    @AppStorage(AppPreferences.allowRemoteKey) private var allowRemote = AppPreferences.defaultAllowRemote
    @AppStorage(AppPreferences.secretKeyKey) private var secretKey = AppPreferences.defaultSecretKey
    @AppStorage(AppPreferences.showUsageInMenuBarKey) private var showUsageInMenuBar = AppPreferences.defaultShowUsageInMenuBar
    @AppStorage(AppPreferences.usageAutoRefreshSecondsKey) private var usageAutoRefreshSeconds = AppPreferences.defaultUsageAutoRefreshSeconds
    @AppStorage(AppPreferences.oledThemeKey) private var oledTheme = AppPreferences.defaultOledTheme
    @AppStorage(AppPreferences.backgroundOpacityKey) private var backgroundOpacity = AppPreferences.defaultBackgroundOpacity
    @State private var authenticatingService: ServiceType? = nil
    @State private var showingAuthResult = false
    @State private var authResultMessage = ""
    @State private var authResultSuccess = false
    @State private var showingInfoAlert = false
    @State private var infoAlertMessage = ""
    @State private var authDirectoryMonitor: AuthDirectoryMonitor?
    @State private var expandedRowCount = 0
    @State private var factoryModelsInstalled = false
    @State private var challengerPluginInstalled = false
    @State private var remoteManagementExpanded = false
    @State private var codexFastModeExpanded = true
    private let claudeEffortSelectionColor = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)
    private let codexEffortSelectionColor = Color(red: 0x74/255, green: 0xAA/255, blue: 0x9C/255)
    private let geminiEffortSelectionColor = Color(red: 0x42/255, green: 0x85/255, blue: 0xF4/255)
    private let kimiEffortSelectionColor = Color(red: 0x00/255, green: 0xBF/255, blue: 0x91/255)
    private let oledFooterText = Color(red: 0xA8/255, green: 0xA8/255, blue: 0xA8/255)

    private var oauthUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if oauthUsageTracker.accounts.isEmpty {
                Text("Connect Codex or Claude OAuth accounts to show quota windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(oauthUsageTracker.accounts) { account in
                    oauthUsageAccountRow(account)
                }
            }
        }
        .padding(.top, 4)
    }

    private func oauthUsageAccountRow(_ account: OAuthAccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.provider.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(account.email)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                if account.isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                }
            }

            if let error = account.error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else {
                ForEach(account.windows) { window in
                    usageWindowRow(window)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private func usageWindowRow(_ window: OAuthUsageWindow) -> some View {
        let remaining = window.remainingPercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let remaining {
                    Text("\(Int(remaining.rounded()))% left")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if let remaining {
                ProgressView(value: remaining, total: 100)
                    .tint(remaining < 20 ? .orange : .green)
            } else {
                Text("Usage unavailable")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let resetText = window.resetText {
                Text(resetText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // Translucent row background that reveals the colourful window backdrop.
    // We deliberately avoid .ultraThinMaterial here — on dark appearance it
    // vibrancy-composites to an almost-opaque grey which fights the glass look.
    // A white gradient at low alpha + a hairline inner/outer highlight reads as
    // actual liquid glass against the multi-hue window gradient below.
    @ViewBuilder
    private var glassRowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .padding(.vertical, 2)
    }
    
    private enum Timing {
        static let serverRestartDelay: TimeInterval = 0.3
        static let refreshDebounce: TimeInterval = 0.5
    }

    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "v\(version)"
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LogoView()
                    .padding(.top, 36) // leave room for the transparent titlebar traffic-lights
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.40))
                        Slider(value: $backgroundOpacity, in: 0.10...1.0)
                            .frame(width: 60)
                            .controlSize(.mini)
                            .tint(Color.white.opacity(0.55))
                    }
                    .help("Adjust background opacity (100% = fully opaque)")
                    Button {
                        oledTheme.toggle()
                        NotificationCenter.default.post(name: .droidProxyThemeChanged, object: nil)
                    } label: {
                        Image(systemName: oledTheme ? "sun.max.fill" : "moon.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(oledTheme ? Color.yellow.opacity(0.9) : Color.white.opacity(0.75))
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(oledTheme ? 0.06 : 0.10))
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(oledTheme ? "Switch to Liquid Glass theme" : "Switch to OLED black theme")
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
            }

            Form {
                Section {
                    HStack {
                        Text("Server status")
                        Spacer()
                        Button(action: {
                            if serverManager.isRunning {
                                serverManager.stop()
                            } else {
                                serverManager.start { _ in }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(serverManager.isRunning ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(serverManager.isRunning ? "Running" : "Stopped")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .droidGlassCapsule(
                                tint: serverManager.isRunning ? Color.green.opacity(0.4) : Color.red.opacity(0.4),
                                interactive: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(glassRowBackground)

                if serverManager.isProviderEnabled(.codex) || authManager.hasAccounts(for: .codex) ||
                   serverManager.isProviderEnabled(.claude) || authManager.hasAccounts(for: .claude) {
                    Section {
                        HStack {
                            Text("OAuth Quota Usage")
                            Spacer()
                            Button(action: refreshOAuthUsage) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(oauthUsageTracker.isRefreshing)
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .opacity(oauthUsageTracker.isRefreshing ? 0.5 : 1)
                            .help("Refresh usage quotas")
                        }
                        oauthUsageDashboard
                    }
                    .listRowBackground(glassRowBackground)
                }

                Section {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(newValue)
                        }

                    HStack {
                        Text("Auth files")
                        Spacer()
                        Button("Open Folder") {
                            openAuthFolder()
                        }
                        .droidGlassPlain()
                        .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Factory custom models")
                            Spacer()
                            if factoryModelsInstalled {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                    Text("Applied")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            Button(factoryModelsInstalled ? "Re-apply" : "Apply") {
                                applyFactoryCustomModels()
                            }
                            .droidGlassProminent()
                            .controlSize(.small)
                        }

                        Text("Apply writes DroidProxy model aliases into ~/.factory/settings.json. Each model exposes its full reasoning level set (low/medium/high/xhigh/max) directly in Factory's per-session selector — pick the level from Droid CLI, not here.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                    HStack {
                        Text("Challenger Plugin")
                        Button {
                            infoAlertMessage = "Installs three devil's advocate code reviewer droids (Opus 4.7, GPT 5.2, Gemini 3.1 Pro) and their slash commands into your Factory config. Use /challenge-opus, /challenge-gpt, or /challenge-gemini in any Droid session for a cross-model second opinion on your code."
                            showingInfoAlert = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About Challenger Plugin")
                        .help("About Challenger Plugin")
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        Spacer()
                        if challengerPluginInstalled {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Applied")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        Button(challengerPluginInstalled ? "Re-apply" : "Apply") {
                            applyChallengerPlugin()
                        }
                        .droidGlassProminent()
                        .controlSize(.small)
                    }
                }
                .listRowBackground(glassRowBackground)

                Section {
                    Toggle("Show usage in menu bar", isOn: $showUsageInMenuBar)
                        .onChange(of: showUsageInMenuBar) { _ in
                            NotificationCenter.default.post(name: .usageUpdated, object: nil)
                        }
                    
                    HStack {
                        Text("Auto-refresh usage")
                        Spacer()
                        Picker("", selection: $usageAutoRefreshSeconds) {
                            Text("Manual").tag(0)
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                            Text("10 minutes").tag(600)
                            Text("30 minutes").tag(1800)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                        .onChange(of: usageAutoRefreshSeconds) { _ in
                            UsageStore.shared.scheduleTimer()
                        }
                    }
                    
                    HStack {
                        Spacer()
                        Button("Refresh now") {
                            UsageStore.shared.refresh()
                        }
                        .controlSize(.small)
                    }
                }
                .listRowBackground(glassRowBackground)

                Section {
                    if remoteManagementExpanded {
                        Toggle("Allow remote access", isOn: $allowRemote)
                            .onChange(of: allowRemote) { _ in
                                _ = serverManager.getConfigPath()
                            }

                        HStack {
                            Text("Secret key")
                            Spacer()
                            SecureField("Enter secret key", text: $secretKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                                .onSubmit {
                                    _ = serverManager.getConfigPath()
                                }
                        }

                        if allowRemote && secretKey.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Set a secret key to secure remote access")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(allowRemote ? "Remote access: On" : "Remote access: Off")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if allowRemote && secretKey.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Secret key missing")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            remoteManagementExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Remote Management")
                            Image(systemName: remoteManagementExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remote Management")
                    .accessibilityValue(remoteManagementExpanded ? "Expanded" : "Collapsed")
                }
                .listRowBackground(glassRowBackground)

                Section("Services") {
                    ServiceRow(
                        serviceType: .claude,
                        iconName: "icon-claude.png",
                        accounts: authManager.accounts(for: .claude),
                        isAuthenticating: authenticatingService == .claude,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled(.claude),
                        customTitle: nil,
                        onConnect: { connectService(.claude) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled(.claude, enabled: enabled) },
                        toggleTint: claudeEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .codex,
                        iconName: "icon-codex.png",
                        accounts: authManager.accounts(for: .codex),
                        isAuthenticating: authenticatingService == .codex,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled(.codex),
                        customTitle: nil,
                        onConnect: { connectService(.codex) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled(.codex, enabled: enabled) },
                        toggleTint: codexEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    if serverManager.isProviderEnabled(.codex) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Fast Mode")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: codexFastModeExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    codexFastModeExpanded.toggle()
                                }
                            }
                            if codexFastModeExpanded {
                                codexFastModeToggleRow(
                                    "GPT 5.2",
                                    isOn: $gpt52FastMode,
                                    helpText: "Injects service_tier=priority for GPT 5.2 Responses API requests (Codex fast mode)"
                                )
                                codexFastModeToggleRow(
                                    "GPT 5.3 Codex",
                                    isOn: $gpt53CodexFastMode,
                                    helpText: "Injects service_tier=priority for GPT 5.3 Codex Responses API requests (Codex fast mode)"
                                )
                                codexFastModeToggleRow(
                                    "GPT 5.4",
                                    isOn: $gpt54FastMode,
                                    helpText: "Injects service_tier=priority for GPT 5.4 Responses API requests (Codex fast mode)"
                                )
                                codexFastModeToggleRow(
                                    "GPT 5.5",
                                    isOn: $gpt55FastMode,
                                    helpText: "Injects service_tier=priority for GPT 5.5 Responses API requests (Codex fast mode)"
                                )
                            }
                        }
                        .padding(.leading, 28)
                    }

                    ServiceRow(
                        serviceType: .gemini,
                        iconName: "icon-gemini.png",
                        accounts: authManager.accounts(for: .gemini),
                        isAuthenticating: authenticatingService == .gemini,
                        helpText: "If you have multiple GCP projects, authentication will use your default project. Set your desired project as default in Google AI Studio before connecting.",
                        isEnabled: serverManager.isProviderEnabled(.gemini),
                        customTitle: nil,
                        onConnect: { connectService(.gemini) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled(.gemini, enabled: enabled) },
                        toggleTint: geminiEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    ServiceRow(
                        serviceType: .kimi,
                        iconName: "icon-kimi.svg",
                        accounts: authManager.accounts(for: .kimi),
                        isAuthenticating: authenticatingService == .kimi,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled(.kimi),
                        customTitle: nil,
                        onConnect: { connectService(.kimi) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled(.kimi, enabled: enabled) },
                        toggleTint: kimiEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                }
                .listRowBackground(glassRowBackground)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(false)

            Spacer()
                .frame(height: 6)

            // Footer
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("DroidProxy \(appVersion) was made possible thanks to")
                        .font(.caption)
                        .foregroundColor(oledFooterText)
                    Link("CLIProxyAPIPlus", destination: URL(string: "https://github.com/router-for-me/CLIProxyAPIPlus")!)
                        .font(.caption)
                        .underline()
                        .foregroundColor(oledFooterText)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    Text("|")
                        .font(.caption)
                        .foregroundColor(oledFooterText)
                    Text("License: MIT")
                        .font(.caption)
                        .foregroundColor(oledFooterText)
                }

                HStack(spacing: 4) {
                    Text("© 2026")
                        .font(.caption)
                        .foregroundColor(oledFooterText)
                    Text("DroidProxy")
                        .font(.caption)
                        .foregroundColor(oledFooterText)
                }

                Link("Report an issue", destination: URL(string: "https://github.com/anand-92/droidproxy/issues")!)
                    .font(.caption)
                    .foregroundColor(oledFooterText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .droidGlassCapsule(tint: Color.white.opacity(0.08), interactive: true)
                    .padding(.top, 6)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
            .padding(.bottom, 12)
        }
        .background(
            ZStack {
                if oledTheme {
                    Color.black.ignoresSafeArea()
                } else {
                    if backgroundOpacity < 1.0 {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                            .ignoresSafeArea()
                    }
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                    RadialGradient(
                        colors: [Color(red: 0.95, green: 0.45, blue: 0.15).opacity(0.45), Color.clear],
                        center: .init(x: 0.15, y: 0.1), startRadius: 10, endRadius: 420
                    ).ignoresSafeArea()
                    RadialGradient(
                        colors: [Color(red: 0.30, green: 0.50, blue: 0.95).opacity(0.35), Color.clear],
                        center: .init(x: 0.85, y: 0.9), startRadius: 10, endRadius: 420
                    ).ignoresSafeArea()
                    RadialGradient(
                        colors: [Color(red: 0.90, green: 0.25, blue: 0.35).opacity(0.25), Color.clear],
                        center: .init(x: 0.9, y: 0.2), startRadius: 10, endRadius: 320
                    ).ignoresSafeArea()
                }
            }
            .opacity(backgroundOpacity)
        )
        .accentColor(AccountRowView.accent)
        .preferredColorScheme(.dark)
        .frame(width: 480, height: 814)
        .onChange(of: backgroundOpacity) { _ in
            NotificationCenter.default.post(name: .droidProxyThemeChanged, object: nil)
        }
        .onAppear {
            authManager.checkAuthStatus()
            checkLaunchAtLogin()
            startMonitoringAuthDirectory()
            factoryModelsInstalled = checkFactoryModelsInstalled()
            challengerPluginInstalled = checkChallengerPluginInstalled()
            refreshOAuthUsage()
        }
        .onChange(of: codexUsageAccountSignature) { _ in
            refreshOAuthUsage()
        }
        .onDisappear {
            stopMonitoringAuthDirectory()
        }
        .alert("Authentication Result", isPresented: $showingAuthResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authResultMessage)
        }
        .alert("About", isPresented: $showingInfoAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(infoAlertMessage)
        }
        .alert("About", isPresented: $showingInfoAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(infoAlertMessage)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func codexFastModeToggleRow(_ title: String, isOn: Binding<Bool>, helpText: String) -> some View {
        HStack {
            Text("\(title) fast mode")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Toggle("Fast mode", isOn: isOn)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(helpText)
        }
        .padding(.vertical, 2)
    }

    
    private func toggleAccountDisabled(_ account: AuthAccount) {
        if authManager.toggleAccountDisabled(account) {
            authResultSuccess = true
            authResultMessage = account.isDisabled
                ? "✓ Enabled \(account.displayName)"
                : "✓ Disabled \(account.displayName)"
            showingAuthResult = true
        } else {
            authResultSuccess = false
            authResultMessage = "Failed to update \(account.displayName). Please try again."
            showingAuthResult = true
        }
    }

    private func refreshOAuthUsage() {
        oauthUsageTracker.refresh(
            codexAccounts: authManager.accounts(for: .codex),
            claudeAccounts: authManager.accounts(for: .claude)
        )
    }

    private var codexUsageAccountSignature: String {
        let codexSig = authManager.accounts(for: .codex)
            .filter { !$0.isDisabled && !$0.isExpired }
            .map(\.id)
            .sorted()
            .joined(separator: "|")
        let claudeSig = authManager.accounts(for: .claude)
            .filter { !$0.isDisabled && !$0.isExpired }
            .map(\.id)
            .sorted()
            .joined(separator: "|")
        return "\(codexSig)||\(claudeSig)"
    }
    
    private func openAuthFolder() {
        let authDir = AuthPaths.authDirectory
        NSWorkspace.shared.open(authDir)
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[SettingsView] Failed to toggle launch at login: %@", error.localizedDescription)
            }
        }
    }

    private func checkLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
    
    private func connectService(_ serviceType: ServiceType) {
        authenticatingService = serviceType
        NSLog("[SettingsView] Starting %@ authentication", serviceType.displayName)
        
        let command: AuthCommand
        switch serviceType {
        case .claude: command = .claudeLogin
        case .codex: command = .codexLogin
        case .gemini: command = .geminiLogin
        case .kimi: command = .kimiLogin
        }
        
        serverManager.runAuthCommand(command) { success, output in
            NSLog("[SettingsView] Auth completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingService = nil
                
                if success {
                    self.authResultSuccess = true
                    self.authResultMessage = self.successMessage(for: serviceType)
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    self.authResultMessage = "Authentication failed. Please check if the browser opened and try again.\n\nDetails: \(output.isEmpty ? "No output from authentication process" : output)"
                    self.showingAuthResult = true
                }
            }
        }
    }
    
    private func successMessage(for serviceType: ServiceType) -> String {
        switch serviceType {
        case .claude:
            return "🌐 Browser opened for Claude Code authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .codex:
            return "🌐 Browser opened for Codex authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .gemini:
            return "🌐 Browser opened for Gemini authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.\n\nIf having issues, run in terminal:\n/Applications/DroidProxy.app/Contents/Resources/cli-proxy-api-plus --config ~/.cli-proxy-api/merged-config.yaml -login"
        case .kimi:
            return "🌐 Browser opened for Kimi authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        }
    }
    
    private func disconnectAccount(_ account: AuthAccount) {
        let wasRunning = serverManager.isRunning
        
        // Stop server, delete file, restart
        let cleanup = {
            if self.authManager.deleteAccount(account) {
                self.authResultSuccess = true
                self.authResultMessage = "✓ Removed \(account.displayName) from \(account.type.displayName)"
            } else {
                self.authResultSuccess = false
                self.authResultMessage = "Failed to remove account"
            }
            self.showingAuthResult = true
            
            if wasRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.serverRestartDelay) {
                    self.serverManager.start { _ in }
                }
            }
        }
        
        if wasRunning {
            serverManager.stop { cleanup() }
        } else {
            cleanup()
        }
    }
    
    // MARK: - Factory Custom Models

    /// Ids retired by prior releases. Removed from `customModels` during Apply/Re-apply
    /// so users don't end up with stale entries next to the current ones.
    private static let legacyDroidProxyModelIds: Set<String> = []

    private func factorySettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory")
            .appendingPathComponent("settings.json")
    }

    private func checkFactoryModelsInstalled() -> Bool {
        let url = factorySettingsURL()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["customModels"] as? [[String: Any]] else {
            return false
        }
        let enabledModels = DroidProxyModelCatalog.settingsModels().filter { model in
            guard let key = DroidProxyModelCatalog.providerKey(forSettingsModel: model),
                  let serviceType = ServiceType(authFileType: key) else { return true }
            return serverManager.isProviderEnabled(serviceType)
        }
        let expectedIds = Set(enabledModels.compactMap { $0["id"] as? String })
        let installedDroidProxyIds = Set(models.compactMap { $0["id"] as? String }.filter { id in
            DroidProxyModelCatalog.allSettingsIDs.contains(id)
                || Self.legacyDroidProxyModelIds.contains(id)
                || id.hasPrefix("custom:droidproxy:")
                || id.hasPrefix("custom:CC:")
        })
        return !expectedIds.isEmpty && installedDroidProxyIds == expectedIds
    }

    private func applyFactoryCustomModels() {
        let url = factorySettingsURL()
        let factoryDir = url.deletingLastPathComponent()

        try? FileManager.default.createDirectory(at: factoryDir, withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var models = (settings["customModels"] as? [[String: Any]]) ?? []

        models.removeAll { item in
            guard let id = item["id"] as? String else { return false }
            return DroidProxyModelCatalog.allSettingsIDs.contains(id)
                || Self.legacyDroidProxyModelIds.contains(id)
                || id.hasPrefix("custom:droidproxy:")
                || id.hasPrefix("custom:CC:")
        }

        let enabledModels = DroidProxyModelCatalog.settingsModels().filter { model in
            guard let key = DroidProxyModelCatalog.providerKey(forSettingsModel: model),
                  let serviceType = ServiceType(authFileType: key) else { return true }
            return serverManager.isProviderEnabled(serviceType)
        }
        let startIndex = models.count
        for (offset, var model) in enabledModels.enumerated() {
            model["index"] = startIndex + offset
            models.append(model)
        }

        settings["customModels"] = models

        do {
            var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            if var jsonString = String(data: data, encoding: .utf8) {
                jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")
                data = jsonString.data(using: .utf8) ?? data
            }
            try data.write(to: url, options: .atomic)
            factoryModelsInstalled = true
            authResultSuccess = true
            authResultMessage = "DroidProxy models added to Factory settings.\n\nReasoning effort is controlled from Droid CLI per session (low / medium / high / xhigh / max as supported by each model). Restart Factory or open a new session to see them in the model picker."
            showingAuthResult = true
            NSLog("[SettingsView] Factory custom models applied to %@", url.path)
        } catch {
            authResultSuccess = false
            authResultMessage = "Failed to update Factory settings: \(error.localizedDescription)"
            showingAuthResult = true
            NSLog("[SettingsView] Failed to apply Factory custom models: %@", error.localizedDescription)
        }
    }

    // MARK: - Challenger Plugin

    private static let challengerPluginFiles: [(directory: String, filename: String, content: String)] = [
        ("droids", "challenger-opus.md", """
        ---
        name: challenger-opus
        description: Devil's advocate code reviewer that challenges decisions, critiques patterns, and suggests better alternatives. Use when you want a tough second opinion on code, architecture, or design choices.
        model: custom:droidproxy:opus-4-7
        tools: ["Read", "LS", "Grep", "Glob", "WebSearch", "FetchUrl"]
        ---

        You are a senior engineer playing devil's advocate. Your job is to challenge every code decision presented to you and push for better alternatives. You are constructive but relentless.

        When reviewing code or decisions:

        1. **Question the "why"** - Don't accept decisions at face value. Ask why this approach was chosen over alternatives.
        2. **Find the tradeoffs** - Every decision has costs. Surface the ones the author may not have considered.
        3. **Suggest concrete alternatives** - Don't just criticize; propose better approaches with reasoning.
        4. **Stress-test edge cases** - Think about failure modes, scale, concurrency, and maintainability.
        5. **Challenge patterns** - If a pattern is used, question whether it's the right abstraction or if it adds unnecessary complexity.
        6. **Check for over-engineering** - Call out when something is more complex than it needs to be.
        7. **Check for under-engineering** - Call out when shortcuts will cause pain later.

        If needed, use web search to back up your arguments with industry best practices, known pitfalls, or better patterns from well-regarded projects.

        Respond with:

        **Verdict:** <one-line overall assessment>

        **Challenges:**
        - <decision challenged>: <why it's questionable> \u{2192} <suggested alternative>

        **Edge Cases / Risks:**
        - <scenario that could break or degrade>

        **What's Actually Good:**
        - <acknowledge solid decisions so feedback is balanced>
        """),
        ("droids", "challenger-gpt.md", """
        ---
        name: challenger-gpt
        description: Devil's advocate code reviewer that challenges decisions, critiques patterns, and suggests better alternatives. Use when you want a tough second opinion on code, architecture, or design choices.
        model: custom:droidproxy:gpt-5.2
        tools: ["Read", "LS", "Grep", "Glob", "WebSearch", "FetchUrl"]
        ---

        You are a senior engineer playing devil's advocate. Your job is to challenge every code decision presented to you and push for better alternatives. You are constructive but relentless.

        When reviewing code or decisions:

        1. **Question the "why"** - Don't accept decisions at face value. Ask why this approach was chosen over alternatives.
        2. **Find the tradeoffs** - Every decision has costs. Surface the ones the author may not have considered.
        3. **Suggest concrete alternatives** - Don't just criticize; propose better approaches with reasoning.
        4. **Stress-test edge cases** - Think about failure modes, scale, concurrency, and maintainability.
        5. **Challenge patterns** - If a pattern is used, question whether it's the right abstraction or if it adds unnecessary complexity.
        6. **Check for over-engineering** - Call out when something is more complex than it needs to be.
        7. **Check for under-engineering** - Call out when shortcuts will cause pain later.

        If needed, use web search to back up your arguments with industry best practices, known pitfalls, or better patterns from well-regarded projects.

        Respond with:

        **Verdict:** <one-line overall assessment>

        **Challenges:**
        - <decision challenged>: <why it's questionable> \u{2192} <suggested alternative>

        **Edge Cases / Risks:**
        - <scenario that could break or degrade>

        **What's Actually Good:**
        - <acknowledge solid decisions so feedback is balanced>
        """),
        ("droids", "challenger-gemini.md", """
        ---
        name: challenger-gemini
        description: Devil's advocate code reviewer that challenges decisions, critiques patterns, and suggests better alternatives. Use when you want a tough second opinion on code, architecture, or design choices.
        model: custom:droidproxy:gemini-3.1-pro
        tools: ["Read", "LS", "Grep", "Glob", "WebSearch", "FetchUrl"]
        ---

        You are a senior engineer playing devil's advocate. Your job is to challenge every code decision presented to you and push for better alternatives. You are constructive but relentless.

        When reviewing code or decisions:

        1. **Question the "why"** - Don't accept decisions at face value. Ask why this approach was chosen over alternatives.
        2. **Find the tradeoffs** - Every decision has costs. Surface the ones the author may not have considered.
        3. **Suggest concrete alternatives** - Don't just criticize; propose better approaches with reasoning.
        4. **Stress-test edge cases** - Think about failure modes, scale, concurrency, and maintainability.
        5. **Challenge patterns** - If a pattern is used, question whether it's the right abstraction or if it adds unnecessary complexity.
        6. **Check for over-engineering** - Call out when something is more complex than it needs to be.
        7. **Check for under-engineering** - Call out when shortcuts will cause pain later.

        If needed, use web search to back up your arguments with industry best practices, known pitfalls, or better patterns from well-regarded projects.

        Respond with:

        **Verdict:** <one-line overall assessment>

        **Challenges:**
        - <decision challenged>: <why it's questionable> \u{2192} <suggested alternative>

        **Edge Cases / Risks:**
        - <scenario that could break or degrade>

        **What's Actually Good:**
        - <acknowledge solid decisions so feedback is balanced>
        """),
        ("commands", "challenge-opus.md", """
        ---
        description: Summon the Challenger droid (Opus) to review code, decisions, and design
        ---

        Launch the challenger-opus droid to review the current code changes, decisions, or design being discussed in this conversation.

        Steps:
        1. Gather context: run `git diff` (or use the recent conversation context) to understand what's being reviewed.
        2. Use the Task tool to launch the subagent:
           - `challenger-opus`
        3. Pass it the relevant code, design decisions, or architecture being discussed.
        4. Once it responds, present a summary of findings and actionable items.

        Keep the summary concise and actionable. Focus on real issues, not nitpicks.
        """),
        ("commands", "challenge-gpt.md", """
        ---
        description: Summon the Challenger droid (GPT) to review code, decisions, and design
        ---

        Launch the challenger-gpt droid to review the current code changes, decisions, or design being discussed in this conversation.

        Steps:
        1. Gather context: run `git diff` (or use the recent conversation context) to understand what's being reviewed.
        2. Use the Task tool to launch the subagent:
           - `challenger-gpt`
        3. Pass it the relevant code, design decisions, or architecture being discussed.
        4. Once it responds, present a summary of findings and actionable items.

        Keep the summary concise and actionable. Focus on real issues, not nitpicks.
        """),
        ("commands", "challenge-gemini.md", """
        ---
        description: Summon the Challenger droid (Gemini) to review code, decisions, and design
        ---

        Launch the challenger-gemini droid to review the current code changes, decisions, or design being discussed in this conversation.

        Steps:
        1. Gather context: run `git diff` (or use the recent conversation context) to understand what's being reviewed.
        2. Use the Task tool to launch the subagent:
           - `challenger-gemini`
        3. Pass it the relevant code, design decisions, or architecture being discussed.
        4. Once it responds, present a summary of findings and actionable items.

        Keep the summary concise and actionable. Focus on real issues, not nitpicks.
        """)
    ]

    private func checkChallengerPluginInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory")
        return Self.challengerPluginFiles.allSatisfy { entry in
            let url = home.appendingPathComponent(entry.directory).appendingPathComponent(entry.filename)
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            return existing == renderedChallengerPluginContent(entry.content)
        }
    }

    private func renderedChallengerPluginContent(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var s = String(line)
                while s.hasPrefix("        ") { s = String(s.dropFirst(8)) }
                return s
            }
            .joined(separator: "\n")
    }

    private func applyChallengerPlugin() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory")
        let fm = FileManager.default

        do {
            for entry in Self.challengerPluginFiles {
                let dir = home.appendingPathComponent(entry.directory)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = dir.appendingPathComponent(entry.filename)
                try renderedChallengerPluginContent(entry.content).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            challengerPluginInstalled = true
            authResultSuccess = true
            authResultMessage = "Challenger droids and slash commands installed.\n\nUse /challenge-opus, /challenge-gpt, or /challenge-gemini in any Droid session."
            showingAuthResult = true
            NSLog("[SettingsView] Challenger plugin installed to ~/.factory")
        } catch {
            authResultSuccess = false
            authResultMessage = "Failed to install Challenger plugin: \(error.localizedDescription)"
            showingAuthResult = true
            NSLog("[SettingsView] Failed to install Challenger plugin: %@", error.localizedDescription)
        }
    }

    // MARK: - File Monitoring
    
    private func startMonitoringAuthDirectory() {
        authDirectoryMonitor = AuthDirectoryMonitor(debounceInterval: Timing.refreshDebounce, logPrefix: "[FileMonitor]") {
            authManager.checkAuthStatus()
        }
        authDirectoryMonitor?.start()
    }
    
    private func stopMonitoringAuthDirectory() {
        authDirectoryMonitor?.stop()
        authDirectoryMonitor = nil
    }
}
