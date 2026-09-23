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

    /// Pushes the pointing-hand cursor while hovered. The `enabled` flag lets
    /// callers gate the cursor change on a runtime condition (e.g. disabled
    /// buttons should keep the default cursor).
    func pointingHandCursor(enabled: Bool = true) -> some View {
        onHover { inside in
            guard enabled else { return }
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
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

    private var statusColor: Color {
        if account.isDisabled { return .gray }
        if account.isExpired { return Self.accent.opacity(0.6) }
        return Self.accent
    }

    private var nameColor: Color {
        if account.isDisabled { return .secondary.opacity(0.5) }
        if account.isExpired { return Self.accent.opacity(0.6) }
        return .secondary
    }

    private func disableButtonColor(canDisable: Bool) -> Color {
        if account.isDisabled { return Self.accent }
        return canDisable ? Self.accent.opacity(0.6) : .secondary.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(account.displayName)
                .font(.caption)
                .foregroundColor(nameColor)
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
                        .foregroundColor(disableButtonColor(canDisable: canDisable))
                }
                .buttonStyle(.plain)
                .disabled(!canDisable)
                .help(!canDisable ? "At least one account must remain enabled" : "")
                .pointingHandCursor(enabled: canDisable)
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
            .pointingHandCursor()
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
                                Text(AppPreferences.sequentialAccountFailover
                                     ? "• Sequential auto-failover" : "• Round-robin w/ auto-failover")
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
    @ObservedObject var copilotGateway: CopilotGatewayManager
    @ObservedObject var metaMuseAuth: MetaMuseAuthManager
    @StateObject private var authManager = AuthManager()
    @StateObject private var oauthUsageTracker = OAuthUsageTracker()
    @State private var launchAtLogin = false
    @AppStorage(AppPreferences.gpt6AstraFastModeKey) private var gpt6AstraFastMode = AppPreferences.defaultGpt6AstraFastMode
    @AppStorage(AppPreferences.gpt6SolFastModeKey) private var gpt6SolFastMode = AppPreferences.defaultGpt6SolFastMode
    @AppStorage(AppPreferences.gpt6LunaFastModeKey) private var gpt6LunaFastMode = AppPreferences.defaultGpt6LunaFastMode
    @AppStorage(AppPreferences.metaContributorModeKey) private var metaContributorMode = AppPreferences.defaultMetaContributorMode
    @AppStorage(AppPreferences.allowRemoteKey) private var allowRemote = AppPreferences.defaultAllowRemote
    @AppStorage(AppPreferences.secretKeyKey) private var secretKey = AppPreferences.defaultSecretKey
    @AppStorage(AppPreferences.bindAddressKey) private var bindAddress = AppPreferences.defaultBindAddress
    @AppStorage(AppPreferences.oledThemeKey) private var oledTheme = AppPreferences.defaultOledTheme
    @AppStorage(AppPreferences.backgroundOpacityKey) private var backgroundOpacity = AppPreferences.defaultBackgroundOpacity
    @AppStorage(AppPreferences.betaFlagKey) private var betaFlag = AppPreferences.defaultBetaFlag
    @AppStorage(AppPreferences.verboseLoggingKey) private var verboseLogging = AppPreferences.defaultVerboseLogging
    @AppStorage(AppPreferences.sequentialAccountFailoverKey) private var sequentialAccountFailover = AppPreferences.defaultSequentialAccountFailover
    @State private var authenticatingService: ServiceType? = nil
    @State private var showingAuthResult = false
    @State private var authResultMessage = ""
    @State private var showingJunieApiKeyAlert = false
    @State private var junieApiKey = ""
    @State private var grokLoginSession: GrokAuth.LoginSession?
    @State private var grokUserCode: String?
    @State private var copilotDeviceCode: String?
    @State private var copilotVerificationURL: URL?
    @State private var metaDeviceCode: String?
    @State private var metaVerificationURL: URL?
    @State private var authDirectoryMonitor: AuthDirectoryMonitor?
    @State private var expandedRowCount = 0
    @State private var factoryModelsInstalled = false
    @State private var remoteManagementExpanded = false
    @State private var advancedExpanded = false
    @State private var factoryCTAPulse = false
    @State private var factoryJustApplied = false
    @State private var codexFastModeExpanded = true
    @State private var copilotModelsExpanded = true
    @State private var copilotModelSlots: [String]
    private let claudeEffortSelectionColor = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)
    private let codexEffortSelectionColor = Color(red: 0x74/255, green: 0xAA/255, blue: 0x9C/255)
    private let antigravityEffortSelectionColor = Color(red: 0x42/255, green: 0x85/255, blue: 0xF4/255)
    private let kimiEffortSelectionColor = Color(red: 0x00/255, green: 0xBF/255, blue: 0x91/255)
    private let junieEffortSelectionColor = Color(red: 0x48/255, green: 0xE0/255, blue: 0x54/255)
    private let grokEffortSelectionColor = Color(red: 0x1D/255, green: 0x9B/255, blue: 0xF0/255)
    private let copilotSelectionColor = Color(red: 0x77/255, green: 0xB9/255, blue: 0xFF/255)
    // Meta's brand blue ("Meta Blue", #0866FF).
    private let metaSelectionColor = Color(red: 0x08/255, green: 0x66/255, blue: 0xFF/255)
    private let oledFooterText = Color(red: 0xA8/255, green: 0xA8/255, blue: 0xA8/255)

    init(
        serverManager: ServerManager,
        copilotGateway: CopilotGatewayManager,
        metaMuseAuth: MetaMuseAuthManager
    ) {
        self.serverManager = serverManager
        self.copilotGateway = copilotGateway
        self.metaMuseAuth = metaMuseAuth
        let selected = CopilotModelPreferences.selectedModelIDs
        _copilotModelSlots = State(
            initialValue: selected + Array(
                repeating: "",
                count: max(0, CopilotModelPreferences.maximumSelectedModels - selected.count)
            )
        )
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
            ZStack(alignment: .top) {
                LogoView()
                    .padding(.top, 36) // leave room for the transparent titlebar traffic-lights
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                HStack {
                    Toggle("Beta", isOn: $betaFlag)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                        .foregroundColor(Color.white.opacity(0.75))
                        .help("Enable beta-gated features")
                        .pointingHandCursor()
                    Spacer()
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
                        .pointingHandCursor()
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
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
                   serverManager.isProviderEnabled(.claude) || authManager.hasAccounts(for: .claude) ||
                   serverManager.isProviderEnabled(.grok) || authManager.hasAccounts(for: .grok) {
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
                        OAuthUsageDashboard(accounts: oauthUsageTracker.accounts)
                    }
                    .listRowBackground(glassRowBackground)
                }

                Section {
                    factoryApplySection()
                }
                .listRowBackground(glassRowBackground)

                Section("Services") {
                    providerServiceRow(
                        .claude,
                        iconName: "icon-claude.png",
                        toggleTint: claudeEffortSelectionColor
                    )

                    providerServiceRow(
                        .codex,
                        iconName: "icon-codex.png",
                        toggleTint: codexEffortSelectionColor
                    )

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
                                    "GPT 6 Astra",
                                    isOn: $gpt6AstraFastMode,
                                    helpText: "Injects service_tier=priority for GPT 6 Astra Responses API requests (Codex fast mode)"
                                )
                                codexFastModeToggleRow(
                                    "GPT 6 Sol",
                                    isOn: $gpt6SolFastMode,
                                    helpText: "Injects service_tier=priority for GPT 6 Sol Responses API requests (Codex fast mode)"
                                )
                                codexFastModeToggleRow(
                                    "GPT 6 Luna",
                                    isOn: $gpt6LunaFastMode,
                                    helpText: "Injects service_tier=priority for GPT 6 Luna Responses API requests (Codex fast mode)"
                                )
                            }
                        }
                        .padding(.leading, 28)
                    }

                    copilotServiceRow()

                    metaServiceRow()

                    if serverManager.isProviderEnabled(.meta) {
                        metaContributorModeRow()
                            .padding(.leading, 28)
                    }

                    providerServiceRow(
                        .antigravity,
                        iconName: "icon-gemini.png",
                        toggleTint: antigravityEffortSelectionColor,
                        helpText: "Uses your Antigravity subscription for the Antigravity-backed Gemini, Claude, and GPT-OSS models."
                    )

                    providerServiceRow(
                        .kimi,
                        iconName: "icon-kimi.svg",
                        toggleTint: kimiEffortSelectionColor
                    )

                    providerServiceRow(
                        .junie,
                        iconName: "icon-junie.svg",
                        toggleTint: junieEffortSelectionColor,
                        helpText: "Enter your JetBrains Junie API key to use your JetBrains AI subscription for Junie Sonnet 5, Opus 5.5, and Fable 5.1."
                    )

                    providerServiceRow(
                        .grok,
                        iconName: "icon-grok.svg",
                        toggleTint: grokEffortSelectionColor,
                        helpText: "Log in with SuperGrok / X Premium+ to use Grok 4.7 and Grok 4.7 Fast (no xAI API key)."
                    )
                }
                .listRowBackground(glassRowBackground)

                Section {
                    advancedSectionContent()
                } header: {
                    // Deliberately NOT animated: easing a height change this
                    // large through SwiftUI Form leaves the NSTableView row
                    // cache out of sync and rows above (Codex Fast Mode)
                    // render overlapped until relaunch. Provider toggles flip
                    // large row groups instantly with no issue — same here.
                    Button {
                        advancedExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Advanced")
                            Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Advanced")
                    .accessibilityValue(advancedExpanded ? "Expanded" : "Collapsed")
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
                    Link("CLIProxyAPI", destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!)
                        .font(.caption)
                        .underline()
                        .foregroundColor(oledFooterText)
                        .pointingHandCursor()
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
                    .pointingHandCursor()
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
        .frame(width: 480)
        .frame(minHeight: 600, idealHeight: 900, maxHeight: .infinity)
        .onChange(of: backgroundOpacity) { _ in
            NotificationCenter.default.post(name: .droidProxyThemeChanged, object: nil)
        }
        .onAppear {
            authManager.checkAuthStatus()
            checkLaunchAtLogin()
            startMonitoringAuthDirectory()
            factoryModelsInstalled = checkFactoryModelsInstalled()
            refreshOAuthUsage()
        }
        .onChange(of: betaFlag) { _ in
            factoryModelsInstalled = checkFactoryModelsInstalled()
        }
        .onChange(of: codexUsageAccountSignature) { _ in
            refreshOAuthUsage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .metaAccountsChanged)) { _ in
            authManager.checkAuthStatus()
            factoryModelsInstalled = checkFactoryModelsInstalled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .metaUsageChanged)) { _ in
            updateMetaUsage()
        }
        .onDisappear {
            stopMonitoringAuthDirectory()
        }
        .alert("Authentication Result", isPresented: $showingAuthResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authResultMessage)
        }
        .alert("Add Junie API Key", isPresented: $showingJunieApiKeyAlert) {
            SecureField("Enter Junie Key", text: $junieApiKey)
            Button("Save") {
                saveJunieApiKey(junieApiKey)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Please enter your JetBrains Junie API key. It will be saved under ~/.cli-proxy-api/junie.json.")
        }
    }

    // MARK: - Factory Apply + Advanced

    /// The single most important control in the app: without Apply, Droid
    /// cannot see any DroidProxy model. The not-applied state is loud (solid
    /// accent fill + pulsing glow); the applied state settles into a quiet
    /// green outline so it stops competing for attention.
    @ViewBuilder
    private func factoryApplySection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(factoryModelsInstalled ? Color.green.opacity(0.15) : AccountRowView.accent.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: factoryModelsInstalled ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(factoryModelsInstalled ? .green : AccountRowView.accent)
                        .scaleEffect(factoryJustApplied ? 1.25 : 1.0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Factory custom models")
                        .fontWeight(.semibold)
                    Text(factoryModelsInstalled
                         ? "Applied — Droid can see DroidProxy models"
                         : "Not applied — Droid can't see models until you apply")
                        .font(.caption)
                        .foregroundColor(factoryModelsInstalled ? .green : AccountRowView.accent)
                }
                Spacer()
            }

            Text("Apply writes DroidProxy model aliases into ~/.factory/settings.json and makes a timestamped backup first. Reasoning effort is selected from Droid CLI when the model exposes multiple levels.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                applyFactoryCustomModels()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    factoryJustApplied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    factoryJustApplied = false
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: factoryJustApplied ? "checkmark" : (factoryModelsInstalled ? "arrow.trianglehead.2.counterclockwise" : "arrow.down.circle.fill"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(factoryJustApplied ? "Applied!" : (factoryModelsInstalled ? "Re-apply Factory Models" : "Apply Factory Models"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundColor(factoryModelsInstalled && !factoryJustApplied ? .green : .white)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(factoryModelsInstalled && !factoryJustApplied
                              ? Color.green.opacity(0.12)
                              : AccountRowView.accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(factoryModelsInstalled && !factoryJustApplied ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .shadow(color: factoryModelsInstalled ? .clear : AccountRowView.accent.opacity(factoryCTAPulse ? 0.55 : 0.25), radius: factoryCTAPulse ? 12 : 6)
                .scaleEffect(factoryModelsInstalled ? 1.0 : (factoryCTAPulse ? 1.015 : 1.0))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel(factoryModelsInstalled ? "Re-apply Factory custom models" : "Apply Factory custom models")
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    factoryCTAPulse = true
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Collapsed-by-default catch-all at the bottom of the stack for settings
    /// most users touch rarely: launch-at-login, auth files, remote
    /// management, logging, and account routing.
    @ViewBuilder
    private func advancedSectionContent() -> some View {
        if advancedExpanded {
            VStack(alignment: .leading, spacing: 12) {
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

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            remoteManagementExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Remote Management")
                                .fontWeight(.medium)
                            Image(systemName: remoteManagementExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remote Management")
                    .accessibilityValue(remoteManagementExpanded ? "Expanded" : "Collapsed")

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

                        if betaFlag {
                            HStack {
                                Text("Bind address")
                                Spacer()
                                TextField("127.0.0.1", text: $bindAddress)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 200)
                                    .disableAutocorrection(true)
                                    .onSubmit {
                                        _ = serverManager.getConfigPath()
                                    }
                            }

                            Text("Default is 127.0.0.1. Set to 0.0.0.0 to allow access from other devices on your network (e.g. Tailscale). Requires server restart.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Logging")
                        .fontWeight(.medium)
                    Toggle("Verbose logging", isOn: $verboseLogging)
                        .onChange(of: verboseLogging) { _ in
                            _ = serverManager.getConfigPath()
                        }
                        .help("Writes verbose backend request/response logs to ~/.cli-proxy-api/logs/. CLIProxyAPI hot-reloads, so no restart is required.")

                    HStack {
                        Text("Logs folder")
                        Spacer()
                        Button("Open Logs") {
                            openLogsFolder()
                        }
                        .droidGlassProminent()
                        .controlSize(.small)
                        .help("Opens ~/.cli-proxy-api/logs/ in Finder. Double-click any log to view it in your default text editor.")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Account Routing")
                        .fontWeight(.medium)
                    Toggle("Sequential account failover", isOn: $sequentialAccountFailover)
                        .onChange(of: sequentialAccountFailover) { newValue in
                            serverManager.setSequentialAccountFailover(newValue)
                        }
                        .help("Use one account at a time instead of spreading requests across all of them. CLIProxyAPI hot-reloads, so no restart is required.")

                    Text("With multiple accounts on the same provider, requests stay on one account until its quota runs out, then move to the next automatically without surfacing an error. The exhausted account is skipped until its quota resets. Leave off to spread requests evenly across every account.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("Launch at login, remote access, logging, account routing")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func copilotServiceRow() -> some View {
        let isEnabled = serverManager.isProviderEnabled(.copilot)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { setCopilotEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(copilotSelectionColor)
                .labelsHidden()
                .help(isEnabled ? "Disable GitHub Copilot" : "Enable GitHub Copilot")

                if let nsImage = IconCatalog.shared.image(
                    named: "icon-copilot.png",
                    resizedTo: NSSize(width: 20, height: 20),
                    template: true
                ) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                        .opacity(isEnabled ? 1.0 : 0.4)
                }
                Text("GitHub Copilot")
                    .fontWeight(.medium)
                    .foregroundColor(isEnabled ? .primary : .secondary)
                Spacer()
                if copilotGateway.isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        cancelCopilotAuthentication()
                    }
                    .droidGlassPlain()
                    .controlSize(.small)
                } else if copilotGateway.hasCredentials {
                    Button("Disconnect") {
                        disconnectCopilot()
                    }
                    .droidGlassPlain()
                    .controlSize(.small)
                } else if isEnabled {
                    Button("Connect") {
                        startCopilotAuthentication()
                    }
                    .droidGlassProminent()
                    .tint(copilotSelectionColor)
                    .controlSize(.small)
                }
            }

            if isEnabled {
                if copilotGateway.isAuthenticating {
                    copilotDeviceCodeRow()
                } else if copilotGateway.hasCredentials {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(copilotGatewayStatusColor)
                            .frame(width: 6, height: 6)
                        Text(copilotGatewayStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if case .failed = copilotGateway.state {
                            Button("Retry") {
                                copilotGateway.start()
                            }
                            .droidGlassPlain()
                            .controlSize(.small)
                        }
                        Button("Refresh Models") {
                            refreshCopilotModels()
                        }
                        .droidGlassPlain()
                        .controlSize(.small)
                        .disabled(!copilotGateway.isRunning)
                    }
                    .padding(.leading, 28)

                    if let failure = copilotGateway.state.failureDescription {
                        Text(failure)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .textSelection(.enabled)
                            .padding(.leading, 28)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    copilotModelPicker()
                } else {
                    Text("Connect your Copilot subscription, then choose up to three account-available models for Factory.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .help("Runs the maintained Copilot API gateway locally on port \(CopilotGatewayManager.gatewayPort).")
    }

    private var copilotGatewayStatusColor: Color {
        switch copilotGateway.state {
        case .running:
            return .green
        case .failed:
            return .red
        case .idle, .starting:
            return .orange
        }
    }

    private var copilotGatewayStatusText: String {
        switch copilotGateway.state {
        case .idle:
            return "Local gateway stopped"
        case .starting:
            return "Local gateway starting"
        case .running:
            return "Local gateway running"
        case .failed:
            return "Local gateway failed to start"
        }
    }

    @ViewBuilder
    private func copilotDeviceCodeRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let copilotDeviceCode {
                Text("Complete GitHub Copilot sign-in with this device code:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(copilotDeviceCode)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copilotDeviceCode, forType: .string)
                    }
                    .droidGlassPlain()
                    .controlSize(.small)
                    if let copilotVerificationURL {
                        Link("Open GitHub", destination: copilotVerificationURL)
                            .droidGlassPlain()
                            .controlSize(.small)
                            .pointingHandCursor()
                    }
                }
            } else {
                Text("Waiting for GitHub to provide a device code…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 28)
    }

    @ViewBuilder
    private func copilotModelPicker() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Factory models (\(CopilotModelPreferences.selectedModelIDs.count)/\(CopilotModelPreferences.maximumSelectedModels))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(systemName: copilotModelsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    copilotModelsExpanded.toggle()
                }
            }

            if copilotModelsExpanded {
                if copilotGateway.availableModels.isEmpty {
                    Text("Refresh Models to load the models available to this Copilot account.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(0..<CopilotModelPreferences.maximumSelectedModels, id: \.self) { index in
                        let selectedElsewhere = Set<String>(
                            copilotModelSlots.enumerated().compactMap { slot in
                                guard slot.offset != index, !slot.element.isEmpty else { return nil }
                                return slot.element
                            }
                        )
                        Picker("Model \(index + 1)", selection: copilotModelBinding(at: index)) {
                            Text("Not selected").tag("")
                            ForEach(copilotGateway.availableModels.filter {
                                $0.id == copilotModelSlots[index] || !selectedElsewhere.contains($0.id)
                            }) { model in
                                Text(model.displayName)
                                    .tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("Only the selected models are written into Factory settings when you press Apply or Re-apply.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 28)
    }

    private func copilotModelBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                copilotModelSlots.indices.contains(index) ? copilotModelSlots[index] : ""
            },
            set: { modelID in
                guard copilotModelSlots.indices.contains(index) else { return }
                copilotModelSlots[index] = modelID
                persistCopilotModelSelection()
            }
        )
    }

    private func persistCopilotModelSelection() {
        CopilotModelPreferences.saveSelectedModelIDs(copilotModelSlots)
        let selected = CopilotModelPreferences.selectedModelIDs
        copilotModelSlots = selected + Array(
            repeating: "",
            count: max(0, CopilotModelPreferences.maximumSelectedModels - selected.count)
        )
        factoryModelsInstalled = checkFactoryModelsInstalled()
    }

    private func startCopilotAuthentication() {
        copilotDeviceCode = nil
        copilotVerificationURL = nil
        copilotGateway.startAuthentication(
            onDeviceCode: { code, verificationURL in
                self.copilotDeviceCode = code
                self.copilotVerificationURL = verificationURL
            },
            completion: { result in
                self.copilotDeviceCode = nil
                self.copilotVerificationURL = nil
                switch result {
                case .success:
                    self.copilotGateway.start()
                    self.authResultMessage = "GitHub Copilot connected.\n\nThe local gateway is starting. Select Refresh Models, choose up to three models, then Re-apply Factory custom models."
                case .failure(let error):
                    self.authResultMessage = "GitHub Copilot authentication failed: \(error.localizedDescription)"
                }
                self.showingAuthResult = true
            }
        )
    }

    private func cancelCopilotAuthentication() {
        copilotGateway.cancelAuthentication()
        copilotDeviceCode = nil
        copilotVerificationURL = nil
    }

    private func refreshCopilotModels() {
        copilotGateway.refreshAvailableModels { result in
            switch result {
            case .success(let models):
                let availableIDs = Set(models.map(\.id))
                let retained = CopilotModelPreferences.selectedModelIDs.filter { availableIDs.contains($0) }
                CopilotModelPreferences.saveSelectedModelIDs(retained)
                self.copilotModelSlots = retained + Array(
                    repeating: "",
                    count: max(0, CopilotModelPreferences.maximumSelectedModels - retained.count)
                )
                self.factoryModelsInstalled = self.checkFactoryModelsInstalled()
                self.authResultMessage = "Loaded \(models.count) models available to this GitHub Copilot account. Choose up to three, then Re-apply Factory custom models."
            case .failure(let error):
                self.authResultMessage = "Could not refresh GitHub Copilot models: \(error.localizedDescription)"
            }
            self.showingAuthResult = true
        }
    }

    private func disconnectCopilot() {
        if copilotGateway.disconnect() {
            copilotModelSlots = Array(repeating: "", count: CopilotModelPreferences.maximumSelectedModels)
            CopilotModelPreferences.saveSelectedModelIDs([])
            copilotDeviceCode = nil
            copilotVerificationURL = nil
            factoryModelsInstalled = checkFactoryModelsInstalled()
            authResultMessage = "GitHub Copilot disconnected. Re-apply Factory custom models to remove its selected models."
        } else {
            authResultMessage = "Could not disconnect GitHub Copilot. Please try again."
        }
        showingAuthResult = true
    }

    private func setCopilotEnabled(_ enabled: Bool) {
        serverManager.setProviderEnabled(.copilot, enabled: enabled)
        if enabled, copilotGateway.hasCredentials {
            copilotGateway.start()
        } else if !enabled {
            copilotGateway.stop()
            copilotDeviceCode = nil
            copilotVerificationURL = nil
        }
        factoryModelsInstalled = checkFactoryModelsInstalled()
    }

    // MARK: - Meta Muse

    @ViewBuilder
    private func metaServiceRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            providerServiceRow(
                .meta, iconName: "icon-meta.svg", toggleTint: metaSelectionColor,
                helpText: "Add Meta Muse accounts for automatic account failover.",
                onToggleEnabled: { enabled in
                    if !enabled { cancelMetaAuthentication() }
                    else { metaMuseAuth.refreshAPIKeyIfNeeded() }
                    factoryModelsInstalled = checkFactoryModelsInstalled()
                }
            )
            if serverManager.isProviderEnabled(.meta) {
                if metaMuseAuth.state == .authenticating {
                    metaDeviceCodeRow()
                    Button("Cancel sign-in") { cancelMetaAuthentication() }
                        .droidGlassPlain()
                        .controlSize(.small)
                        .padding(.leading, 28)
                }
                if let error = metaMuseAuth.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.leading, 28)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func metaDeviceCodeRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let metaDeviceCode {
                Text("Complete Meta sign-in with this device code:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(metaDeviceCode)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(metaDeviceCode, forType: .string)
                    }
                    .droidGlassPlain()
                    .controlSize(.small)
                    if let metaVerificationURL {
                        Link("Open Meta", destination: metaVerificationURL)
                            .droidGlassPlain()
                            .controlSize(.small)
                            .pointingHandCursor()
                    }
                }
            } else {
                Text("Waiting for Meta to provide a device code…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 28)
    }

    private func startMetaAuthentication() {
        metaDeviceCode = nil
        metaVerificationURL = nil
        metaMuseAuth.startAuthentication(
            onDeviceCode: { code, verificationURL in
                self.metaDeviceCode = code
                self.metaVerificationURL = verificationURL
            },
            completion: { result in
                self.metaDeviceCode = nil
                self.metaVerificationURL = nil
                switch result {
                case .success:
                    self.authResultMessage = "Meta Muse connected.\n\nMuse Spark 1.3 and Muse Spark 1.3 Contributor are now available. Re-apply Factory custom models to pick them up."
                case .failure(let error):
                    self.authResultMessage = "Meta Muse authentication failed: \(error.localizedDescription)"
                }
                self.factoryModelsInstalled = self.checkFactoryModelsInstalled()
                self.showingAuthResult = true
            }
        )
    }

    private func cancelMetaAuthentication() {
        metaMuseAuth.cancelAuthentication()
        metaDeviceCode = nil
        metaVerificationURL = nil
    }

    /// Same visual language as `codexFastModeToggleRow`, but a single toggle:
    /// Contributor Mode picks `muse-spark-1.3-contributor` instead of
    /// `muse-spark-1.3` when Factory custom models are applied. The two
    /// variants are mutually exclusive - `DroidProxyModelCatalog` only ever
    /// emits one of them.
    @ViewBuilder
    private func metaContributorModeRow() -> some View {
        HStack {
            Text("Muse Spark")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Toggle("Contributor mode", isOn: $metaContributorMode)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Applies Muse Spark 1.3 Contributor instead of Muse Spark 1.3 when Factory custom models are applied. Only one is ever active.")
        }
        .padding(.vertical, 2)
        .onChange(of: metaContributorMode) { _ in
            factoryModelsInstalled = checkFactoryModelsInstalled()
        }
    }

    /// Constructs a `ServiceRow` wired up to the standard auth/server callbacks.
    /// Keeps the body's `Section("Services")` declaration compact and free of
    /// repeated boilerplate per provider.
    @ViewBuilder
    private func providerServiceRow(
        _ serviceType: ServiceType,
        iconName: String,
        toggleTint: Color,
        helpText: String? = nil,
        onToggleEnabled: ((Bool) -> Void)? = nil
    ) -> some View {
        ServiceRow(
            serviceType: serviceType,
            iconName: iconName,
            accounts: authManager.accounts(for: serviceType),
            isAuthenticating: serviceType == .meta ? metaMuseAuth.state == .authenticating : authenticatingService == serviceType,
            helpText: helpText,
            isEnabled: serverManager.isProviderEnabled(serviceType),
            customTitle: nil,
            onConnect: { connectService(serviceType) },
            onDisconnect: { account in disconnectAccount(account) },
            onToggleDisabled: { account in toggleAccountDisabled(account) },
            onToggleEnabled: { enabled in
                serverManager.setProviderEnabled(serviceType, enabled: enabled)
                onToggleEnabled?(enabled)
            },
            toggleTint: toggleTint,
            onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
        ) { EmptyView() }
    }

    @ViewBuilder
    private func codexFastModeToggleRow(_ title: String, isOn: Binding<Bool>, helpText: String) -> some View {
        HStack {
            Text(title)
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
            if account.type == .meta, account.isDisabled {
                metaMuseAuth.refreshAPIKeyIfNeeded()
            }
            authResultMessage = account.isDisabled
                ? "✓ Enabled \(account.displayName)"
                : "✓ Disabled \(account.displayName)"
        } else {
            authResultMessage = "Failed to update \(account.displayName). Please try again."
        }
        showingAuthResult = true
    }

    private func refreshOAuthUsage() {
        oauthUsageTracker.refresh(
            codexAccounts: authManager.accounts(for: .codex),
            claudeAccounts: authManager.accounts(for: .claude),
            grokAccounts: serverManager.isProviderEnabled(.grok) ? authManager.accounts(for: .grok) : [],
            metaAccounts: serverManager.isProviderEnabled(.meta) ? authManager.accounts(for: .meta) : []
        )
    }

    private func updateMetaUsage() {
        oauthUsageTracker.updateMetaAccounts(
            serverManager.isProviderEnabled(.meta) ? authManager.accounts(for: .meta) : []
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
        let grokSig = serverManager.isProviderEnabled(.grok)
            ? authManager.accounts(for: .grok)
                .filter { !$0.isDisabled && !$0.isExpired }
                .map(\.id)
                .sorted()
                .joined(separator: "|")
            : ""
        let metaSig = serverManager.isProviderEnabled(.meta)
            ? authManager.accounts(for: .meta)
                .filter { !$0.isDisabled }
                .map(\.id)
                .sorted()
                .joined(separator: "|")
            : ""
        return "\(codexSig)||\(claudeSig)||\(grokSig)||\(metaSig)"
    }
    
    private func openAuthFolder() {
        let authDir = AuthPaths.authDirectory
        NSWorkspace.shared.open(authDir)
    }

    private func openLogsFolder() {
        let logsDir = AuthPaths.authDirectory.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsDir)
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
        if serviceType == .junie {
            junieApiKey = ""
            showingJunieApiKeyAlert = true
            return
        }

        if serviceType == .grok {
            startGrokOAuthLogin()
            return
        }

        if serviceType == .copilot {
            startCopilotAuthentication()
            return
        }

        if serviceType == .meta {
            startMetaAuthentication()
            return
        }

        authenticatingService = serviceType
        NSLog("[SettingsView] Starting %@ authentication", serviceType.displayName)
        
        let command: AuthCommand
        switch serviceType {
        case .claude: command = .claudeLogin
        case .codex: command = .codexLogin
        case .antigravity: command = .antigravityLogin
        case .kimi: command = .kimiLogin
        case .junie: return // handled by the early-return above; defensive
        case .grok: return // handled by the early-return above; defensive
        case .copilot: return // handled by the early-return above; defensive
        case .meta: return // handled by the early-return above; defensive
        }
        
        serverManager.runAuthCommand(command) { success, output in
            NSLog("[SettingsView] Auth completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingService = nil
                if success {
                    self.authResultMessage = self.successMessage(for: serviceType)
                } else {
                    let details = output.isEmpty ? "No output from authentication process" : output
                    self.authResultMessage = "Authentication failed. Please check if the browser opened and try again.\n\nDetails: \(details)"
                }
                self.showingAuthResult = true
            }
        }
    }
    
    private func successMessage(for serviceType: ServiceType) -> String {
        switch serviceType {
        case .claude:
            return "🌐 Browser opened for Claude Code authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .codex:
            return "🌐 Browser opened for Codex authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .antigravity:
            return "🌐 Browser opened for Antigravity authentication.\n\nYou must have Google Antigravity installed before adding an Antigravity account.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.\n\nIf having issues, run in terminal:\n/Applications/DroidProxy.app/Contents/Resources/cli-proxy-api --config ~/.cli-proxy-api/merged-config.yaml -antigravity-login"
        case .kimi:
            return "🌐 Browser opened for Kimi authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .junie:
            return "✓ Successfully saved Junie API Key."
        case .grok:
            return "🌐 Browser opened for Grok (xAI) authentication.\n\nApprove access for SuperGrok / X Premium+, then DroidProxy will save credentials automatically."
        case .copilot:
            return "🌐 GitHub Copilot sign-in started."
        case .meta:
            return "🌐 Meta Muse sign-in started."
        }
    }

    private func startGrokOAuthLogin() {
        grokLoginSession?.cancel()
        // Drop the old reference immediately so a stale `.cancelled` completion
        // cannot identity-match and clobber the replacement session.
        grokLoginSession = nil
        authenticatingService = .grok
        grokUserCode = nil
        NSLog("[SettingsView] Starting Grok xAI OAuth device login")

        // Holder so closures can identity-check after `startDeviceLogin` returns
        // (Swift forbids capturing the binding before it is declared).
        final class SessionRef {
            var value: GrokAuth.LoginSession?
        }
        let sessionRef = SessionRef()

        let session = GrokAuth.startDeviceLogin(
            onPrompt: { auth in
                DispatchQueue.main.async {
                    guard self.grokLoginSession === sessionRef.value else { return }
                    self.grokUserCode = auth.userCode
                    self.authResultMessage = "🌐 Browser opened for Grok login.\n\nIf prompted, enter code: \(auth.userCode)\n\nWaiting for approval…"
                    self.showingAuthResult = true
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    // Ignore stale completions from a cancelled/replaced session.
                    guard self.grokLoginSession === sessionRef.value else { return }
                    switch result {
                    case .success(let creds):
                        self.authenticatingService = nil
                        self.grokLoginSession = nil
                        self.authManager.checkAuthStatus()
                        let who = creds.email ?? "grok-user"
                        self.authResultMessage = "✓ Grok OAuth connected as \(who).\n\nSelect DroidProxy: Grok 4.7 or DroidProxy: Grok 4.7 Fast in Droid with `/model`."
                        self.showingAuthResult = true
                    case .failure(.cancelled):
                        // Replaced session already cleared `grokLoginSession` above.
                        break
                    case .failure(.reauthRequired):
                        self.authenticatingService = nil
                        self.grokLoginSession = nil
                        self.authResultMessage = "Grok session expired. Reconnect Grok in Settings."
                        self.showingAuthResult = true
                    case .failure(let error):
                        self.authenticatingService = nil
                        self.grokLoginSession = nil
                        self.authResultMessage = "Grok login failed: \(error.localizedDescription)"
                        self.showingAuthResult = true
                    }
                }
            }
        )
        sessionRef.value = session
        grokLoginSession = session
    }

    private func saveJunieApiKey(_ apiKey: String) {
        guard !apiKey.isEmpty else { return }

        let fileURL = AuthPaths.authDirectory.appendingPathComponent("junie.json")
        let json: [String: Any] = [
            "type": "junie",
            "email": "junie-user",
            "apiKey": apiKey,
            "disabled": false
        ]

        do {
            try FileManager.default.createDirectory(at: AuthPaths.authDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try data.write(to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NSLog("[SettingsView] Saved Junie API Key with secure permissions to \(fileURL.path)")

            authManager.checkAuthStatus()

            self.authResultMessage = "✓ Successfully added Junie API Key."
            self.showingAuthResult = true
        } catch {
            NSLog("[SettingsView] Failed to save Junie API Key: \(error.localizedDescription)")
            self.authResultMessage = "Failed to save Junie API Key: \(error.localizedDescription)"
            self.showingAuthResult = true
        }
    }

    private func disconnectAccount(_ account: AuthAccount) {
        if account.type == .meta {
            let removed = authManager.deleteAccount(account)
            authResultMessage = removed ? "Removed \(account.displayName) from Meta Muse" : "Failed to remove account"
            factoryModelsInstalled = checkFactoryModelsInstalled()
            showingAuthResult = true
            return
        }
        let wasRunning = serverManager.isRunning

        // Stop server, delete file, restart
        let cleanup = {
            if self.authManager.deleteAccount(account) {
                self.authResultMessage = "✓ Removed \(account.displayName) from \(account.type.displayName)"
            } else {
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
    private static let legacyDroidProxyModelIds: Set<String> = [
        "custom:droidproxy:grok-4.5",
        "custom:droidproxy:grok-4.6",
        "custom:droidproxy:cursor-composer-2.5",
        "custom:droidproxy:cursor-grok-4.5",
        "custom:droidproxy:cursor-grok-4.5-fast",
        "custom:droidproxy:cursor-grok-4.6",
        "custom:droidproxy:cursor-grok-4.6-fast",
        "custom:droidproxy:cursor-small"
    ]

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
        let enabledModels = enabledFactorySettingsModels()
        let expectedIds = Set(enabledModels.compactMap { $0["id"] as? String })
        let allSettingsIDs = DroidProxyModelCatalog.allSettingsIDs
        let installedDroidProxyIds = Set(models.compactMap { $0["id"] as? String }.filter { id in
            allSettingsIDs.contains(id)
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
        let allSettingsIDs = DroidProxyModelCatalog.allSettingsIDs

        models.removeAll { item in
            guard let id = item["id"] as? String else { return false }
            return allSettingsIDs.contains(id)
                || Self.legacyDroidProxyModelIds.contains(id)
                || id.hasPrefix("custom:droidproxy:")
                || id.hasPrefix("custom:CC:")
        }

        let enabledModels = enabledFactorySettingsModels()
        let startIndex = models.count
        for (offset, var model) in enabledModels.enumerated() {
            model["index"] = startIndex + offset
            models.append(model)
        }

        settings["customModels"] = models

        do {
            backupFactorySettingsIfPresent(url)

            var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            if var jsonString = String(data: data, encoding: .utf8) {
                jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")
                data = jsonString.data(using: .utf8) ?? data
            }
            try data.write(to: url, options: .atomic)
            factoryModelsInstalled = true
            authResultMessage = "DroidProxy models merged into Factory settings.\n\nYour other custom models were kept. Only previous DroidProxy entries were replaced. A timestamped backup was saved next to settings.json.\n\nIn Droid CLI use /model and search for “DroidProxy:”. Restart Factory or open a new session if the picker looks stale. Reasoning effort is controlled from Droid per session when the model exposes multiple levels."
            showingAuthResult = true
            NSLog("[SettingsView] Factory custom models applied to %@", url.path)
        } catch {
            authResultMessage = "Failed to update Factory settings: \(error.localizedDescription)"
            showingAuthResult = true
            NSLog("[SettingsView] Failed to apply Factory custom models: %@", error.localizedDescription)
        }
    }

    private func backupFactorySettingsIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.droidproxy-\(formatter.string(from: Date())).bak")

        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            NSLog("[SettingsView] Backed up Factory settings to %@", backupURL.path)
        } catch {
            NSLog("[SettingsView] Failed to back up Factory settings before applying custom models: %@", error.localizedDescription)
        }
    }

    private func enabledFactorySettingsModels() -> [[String: Any]] {
        DroidProxyModelCatalog.settingsModels { providerKey in
            guard let serviceType = ServiceType(authFileType: providerKey) else { return true }
            return serverManager.isProviderEnabled(serviceType)
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
