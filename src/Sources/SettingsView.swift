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

struct HazardStripesView: View {
    let stripeColor: Color
    let backgroundColor: Color
    private let stripeWidth: CGFloat = 6
    private let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width + geo.size.height
            let count = Int(totalWidth / (stripeWidth + gap)) + 2
            ZStack {
                backgroundColor
                HStack(spacing: gap) {
                    ForEach(0..<count, id: \.self) { _ in
                        Rectangle()
                            .fill(stripeColor)
                            .frame(width: stripeWidth)
                    }
                }
                .frame(width: totalWidth)
                .rotationEffect(.degrees(-45))
            }
        }
        .clipped()
    }
}

struct MaxBudgetToggleView: View {
    @Binding var isOn: Bool
    @State private var isPulsing = false
    @State private var showFlash = false
    @State private var isPressed = false

    private let dangerRed = Color(red: 0.9, green: 0.15, blue: 0.1)
    private let hazardOrange = Color(red: 0.95, green: 0.4, blue: 0.1)
    private let darkRed = Color(red: 0.5, green: 0.05, blue: 0.02)
    private let buttonSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 14) {
            // Button row: label + big red 3D button
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MAX BUDGET MODE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(isOn ? dangerRed : .gray.opacity(0.6))
                    Text("Opus 4.6 + Sonnet 4.6 · max budget_tokens + effort")
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.5))
                }

                Spacer()

                // The Big Red Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isOn.toggle()
                    }
                    if isOn {
                        showFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showFlash = false
                            }
                        }
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            isPulsing = true
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isPulsing = false
                        }
                    }
                } label: {
                    ZStack {
                        // Base shadow / depth (the "well" the button sits in)
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: buttonSize + 6, height: buttonSize + 6)

                        // Outer ring - metallic bezel
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.15), Color.black.opacity(0.3)],
                                    center: .center,
                                    startRadius: buttonSize * 0.35,
                                    endRadius: buttonSize * 0.5
                                )
                            )
                            .frame(width: buttonSize + 4, height: buttonSize + 4)

                        // Main button face - 3D convex gradient
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: isOn
                                        ? [dangerRed, dangerRed.opacity(0.85), darkRed]
                                        : [Color(white: 0.35), Color(white: 0.22), Color(white: 0.12)],
                                    center: .init(x: 0.4, y: 0.35),
                                    startRadius: 0,
                                    endRadius: buttonSize * 0.5
                                )
                            )
                            .frame(width: buttonSize, height: buttonSize)
                            .overlay(
                                // Top highlight for 3D convexity
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.white.opacity(isOn ? 0.25 : 0.15), .clear],
                                            startPoint: .top,
                                            endPoint: .center
                                        )
                                    )
                                    .frame(width: buttonSize - 4, height: buttonSize - 4)
                            )

                        // Power icon on the button
                        Image(systemName: "power")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(isOn ? Color.white : Color.gray.opacity(0.5))

                        // Ignition flash
                        if showFlash {
                            Circle()
                                .fill(Color.white.opacity(0.6))
                                .frame(width: buttonSize, height: buttonSize)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(isPressed ? 0.92 : 1.0)
                }
                .buttonStyle(.plain)
                .shadow(color: isOn ? dangerRed.opacity(isPulsing ? 0.7 : 0.25) : .clear, radius: isOn ? 12 : 0)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isPulsing)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            withAnimation(.easeInOut(duration: 0.1)) { isPressed = true }
                        }
                        .onEnded { _ in
                            withAnimation(.easeOut(duration: 0.15)) { isPressed = false }
                        }
                )
            }

            // Status banner (separate, only when active)
            if isOn {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(hazardOrange)
                        .opacity(isPulsing ? 1.0 : 0.6)
                    Text("\u{26a1} BURNING THROUGH QUOTA")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(dangerRed.opacity(0.9))
                    Spacer()
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.5)
                        .foregroundColor(dangerRed)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        HazardStripesView(
                            stripeColor: dangerRed.opacity(0.15),
                            backgroundColor: Color.red.opacity(0.05)
                        )
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.3))
                    }
                )
                .droidGlassCard(cornerRadius: 5, tint: dangerRed.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(dangerRed.opacity(0.3), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            if isOn {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
        .help("Overrides Opus 4.6 and Sonnet 4.6 effort sliders with classic extended thinking (budget_tokens=63999, effort=max). Opus 4.7 keeps its own slider setting — max mode does not affect it. Ignition is cheap, fuel is not.")
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

    private var activeCount: Int { accounts.filter { !$0.isExpired }.count }
    private var expiredCount: Int { accounts.filter { $0.isExpired }.count }
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
    @State private var launchAtLogin = false
    @AppStorage(AppPreferences.opus47ThinkingEffortKey) private var opus47ThinkingEffort = AppPreferences.defaultOpus47ThinkingEffort
    @AppStorage(AppPreferences.opus46ThinkingEffortKey) private var opus46ThinkingEffort = AppPreferences.defaultOpus46ThinkingEffort
    @AppStorage(AppPreferences.opus45ThinkingEffortKey) private var opus45ThinkingEffort = AppPreferences.defaultOpus45ThinkingEffort
    @AppStorage(AppPreferences.sonnet46ThinkingEffortKey) private var sonnet46ThinkingEffort = AppPreferences.defaultSonnet46ThinkingEffort
    @AppStorage(AppPreferences.gpt52ReasoningEffortKey) private var gpt52ReasoningEffort = AppPreferences.defaultGpt52ReasoningEffort
    @AppStorage(AppPreferences.gpt53CodexReasoningEffortKey) private var gpt53CodexReasoningEffort = AppPreferences.defaultGpt53CodexReasoningEffort
    @AppStorage(AppPreferences.gpt54ReasoningEffortKey) private var gpt54ReasoningEffort = AppPreferences.defaultGpt54ReasoningEffort
    @AppStorage(AppPreferences.gpt55ReasoningEffortKey) private var gpt55ReasoningEffort = AppPreferences.defaultGpt55ReasoningEffort
    @AppStorage(AppPreferences.gpt52FastModeKey) private var gpt52FastMode = AppPreferences.defaultGpt52FastMode
    @AppStorage(AppPreferences.gpt53CodexFastModeKey) private var gpt53CodexFastMode = AppPreferences.defaultGpt53CodexFastMode
    @AppStorage(AppPreferences.gpt54FastModeKey) private var gpt54FastMode = AppPreferences.defaultGpt54FastMode
    @AppStorage(AppPreferences.gpt55FastModeKey) private var gpt55FastMode = AppPreferences.defaultGpt55FastMode
    @AppStorage(AppPreferences.gemini31ProThinkingLevelKey) private var gemini31ProThinkingLevel = AppPreferences.defaultGemini31ProThinkingLevel
    @AppStorage(AppPreferences.gemini3FlashThinkingLevelKey) private var gemini3FlashThinkingLevel = AppPreferences.defaultGemini3FlashThinkingLevel
    @AppStorage(AppPreferences.k26ReasoningEnabledKey) private var k26ReasoningEnabled = AppPreferences.defaultK26ReasoningEnabled
    @AppStorage(AppPreferences.allowRemoteKey) private var allowRemote = AppPreferences.defaultAllowRemote
    @AppStorage(AppPreferences.secretKeyKey) private var secretKey = AppPreferences.defaultSecretKey
    @AppStorage(AppPreferences.claudeMaxBudgetModeKey) private var claudeMaxBudgetMode = AppPreferences.defaultClaudeMaxBudgetMode
    @AppStorage(AppPreferences.showUsageInMenuBarKey) private var showUsageInMenuBar = AppPreferences.defaultShowUsageInMenuBar
    @AppStorage(AppPreferences.usageAutoRefreshSecondsKey) private var usageAutoRefreshSeconds = AppPreferences.defaultUsageAutoRefreshSeconds
    @AppStorage(AppPreferences.oledThemeKey) private var oledTheme = AppPreferences.defaultOledTheme
    @AppStorage(AppPreferences.backgroundOpacityKey) private var backgroundOpacity = AppPreferences.defaultBackgroundOpacity
    @AppStorage(AppPreferences.factoryAdvancedModelsKey) private var factoryAdvancedModels = AppPreferences.defaultFactoryAdvancedModels
    @State private var authenticatingService: ServiceType? = nil
    @State private var showingAuthResult = false
    @State private var authResultMessage = ""
    @State private var authResultSuccess = false
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var pendingRefresh: DispatchWorkItem?
    @State private var expandedRowCount = 0
    @State private var factoryModelsInstalled = false
    @State private var challengerPluginInstalled = false
    @State private var remoteManagementExpanded = false
    @State private var showingMaxBudgetWarning = false
    @State private var claudeModelsExpanded = true
    @State private var codexModelsExpanded = true
    @State private var geminiModelsExpanded = true
    @State private var opus47EffortExpanded = false
    @State private var opus46EffortExpanded = false
    @State private var opus45EffortExpanded = false
    @State private var sonnet46EffortExpanded = false
    private let claudeEffortSelectionColor = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)
    private let codexEffortSelectionColor = Color(red: 0x74/255, green: 0xAA/255, blue: 0x9C/255)
    private let geminiEffortSelectionColor = Color(red: 0x42/255, green: 0x85/255, blue: 0xF4/255)
    private let kimiEffortSelectionColor = Color(red: 0x00/255, green: 0xBF/255, blue: 0x91/255)
    private let oledWindowBackground = Color.black
    private let oledSectionBackground = Color(red: 0x12/255, green: 0x12/255, blue: 0x12/255)
    private let oledFooterText = Color(red: 0xA8/255, green: 0xA8/255, blue: 0xA8/255)

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

                        Toggle("Advanced: add one Factory model entry per reasoning/thinking level", isOn: $factoryAdvancedModels)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .onChange(of: factoryAdvancedModels) { _ in
                                factoryModelsInstalled = checkFactoryModelsInstalled()
                                challengerPluginInstalled = checkChallengerPluginInstalled()
                            }

                        Text(factoryAdvancedModels
                             ? "Apply writes separate Low/Medium/High/etc. model aliases into ~/.factory/settings.json."
                             : "Apply writes the default DroidProxy model aliases into ~/.factory/settings.json.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }

                    HStack {
                        Text("Challenger Plugin")
                        Button(action: {}) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Installs three devil's advocate code reviewer droids (Opus 4.7, GPT 5.2, Gemini 3.1 Pro) and their slash commands into your Factory config. Use /challenge-opus, /challenge-gpt, or /challenge-gemini in any Droid session for a cross-model second opinion on your code.")
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
                        isEnabled: serverManager.isProviderEnabled("claude"),
                        customTitle: nil,
                        onConnect: { connectService(.claude) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("claude", enabled: enabled) },
                        toggleTint: claudeEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    if serverManager.isProviderEnabled("claude") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Model Settings")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: claudeModelsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    claudeModelsExpanded.toggle()
                                }
                            }
                            if claudeModelsExpanded {
                                if factoryAdvancedModels {
                                    advancedFactoryModelsNotice("Claude")
                                } else {
                                    MaxBudgetToggleView(isOn: $claudeMaxBudgetMode)
                                        .onChange(of: claudeMaxBudgetMode) { enabled in
                                            if enabled {
                                                showingMaxBudgetWarning = true
                                                opus46ThinkingEffort = "max"
                                                sonnet46ThinkingEffort = "max"
                                            }
                                        }
                                    collapsibleEffortPickerRow(
                                        "Opus 4.7 thinking effort",
                                        selection: $opus47ThinkingEffort,
                                        options: ["low", "medium", "high", "xhigh", "max"],
                                        tint: claudeEffortSelectionColor,
                                        isExpanded: $opus47EffortExpanded
                                    )
                                    collapsibleEffortPickerRow(
                                        "Opus 4.6 thinking effort",
                                        selection: $opus46ThinkingEffort,
                                        options: ["low", "medium", "high", "max"],
                                        tint: claudeEffortSelectionColor,
                                        isExpanded: $opus46EffortExpanded,
                                        overrideBadge: claudeMaxBudgetMode ? "MAX MODE" : nil
                                    )
                                    .disabled(claudeMaxBudgetMode)
                                    .opacity(claudeMaxBudgetMode ? 0.45 : 1.0)
                                    collapsibleEffortPickerRow(
                                        "Opus 4.5 thinking effort",
                                        selection: $opus45ThinkingEffort,
                                        options: ["low", "medium", "high", "max"],
                                        tint: claudeEffortSelectionColor,
                                        isExpanded: $opus45EffortExpanded
                                    )
                                    collapsibleEffortPickerRow(
                                        "Sonnet 4.6 thinking effort",
                                        selection: $sonnet46ThinkingEffort,
                                        options: ["low", "medium", "high", "max"],
                                        tint: claudeEffortSelectionColor,
                                        isExpanded: $sonnet46EffortExpanded,
                                        overrideBadge: claudeMaxBudgetMode ? "MAX MODE" : nil
                                    )
                                    .disabled(claudeMaxBudgetMode)
                                    .opacity(claudeMaxBudgetMode ? 0.45 : 1.0)
                                }
                            }
                        }
                        .padding(.leading, 28)
                    }

                    ServiceRow(
                        serviceType: .codex,
                        iconName: "icon-codex.png",
                        accounts: authManager.accounts(for: .codex),
                        isAuthenticating: authenticatingService == .codex,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("codex"),
                        customTitle: nil,
                        onConnect: { connectService(.codex) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("codex", enabled: enabled) },
                        toggleTint: codexEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    if serverManager.isProviderEnabled("codex") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Model Settings")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: codexModelsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    codexModelsExpanded.toggle()
                                }
                            }
                            if codexModelsExpanded {
                                if factoryAdvancedModels {
                                    advancedFactoryModelsNotice("Codex")
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
                                } else {
                                    codexReasoningEffortRow(
                                        "GPT 5.2",
                                        effortSelection: $gpt52ReasoningEffort,
                                        fastMode: $gpt52FastMode
                                    )
                                    codexReasoningEffortRow(
                                        "GPT 5.3 Codex",
                                        effortSelection: $gpt53CodexReasoningEffort,
                                        fastMode: $gpt53CodexFastMode
                                    )
                                    codexReasoningEffortRow(
                                        "GPT 5.4",
                                        effortSelection: $gpt54ReasoningEffort,
                                        fastMode: $gpt54FastMode
                                    )
                                    codexReasoningEffortRow(
                                        "GPT 5.5",
                                        effortSelection: $gpt55ReasoningEffort,
                                        fastMode: $gpt55FastMode
                                    )
                                }
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
                        isEnabled: serverManager.isProviderEnabled("gemini"),
                        customTitle: nil,
                        onConnect: { connectService(.gemini) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("gemini", enabled: enabled) },
                        toggleTint: geminiEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    if serverManager.isProviderEnabled("gemini") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Model Settings")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: geminiModelsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    geminiModelsExpanded.toggle()
                                }
                            }
                            if geminiModelsExpanded {
                                if factoryAdvancedModels {
                                    advancedFactoryModelsNotice("Gemini")
                                } else {
                                    effortPickerRow(
                                        "Gemini 3.1 Pro thinking level",
                                        selection: $gemini31ProThinkingLevel,
                                        options: ["low", "medium", "high"],
                                        tint: geminiEffortSelectionColor
                                    )
                                    effortPickerRow(
                                        "Gemini 3 Flash thinking level",
                                        selection: $gemini3FlashThinkingLevel,
                                        options: ["minimal", "low", "medium", "high"],
                                        tint: geminiEffortSelectionColor
                                    )
                                }
                            }
                        }
                        .padding(.leading, 28)
                    }

                    ServiceRow(
                        serviceType: .kimi,
                        iconName: "icon-kimi.svg",
                        accounts: authManager.accounts(for: .kimi),
                        isAuthenticating: authenticatingService == .kimi,
                        helpText: nil,
                        isEnabled: serverManager.isProviderEnabled("kimi"),
                        customTitle: nil,
                        onConnect: { connectService(.kimi) },
                        onDisconnect: { account in disconnectAccount(account) },
                        onToggleDisabled: { account in toggleAccountDisabled(account) },
                        onToggleEnabled: { enabled in serverManager.setProviderEnabled("kimi", enabled: enabled) },
                        toggleTint: kimiEffortSelectionColor,
                        onExpandChange: { expanded in expandedRowCount += expanded ? 1 : -1 }
                    ) { EmptyView() }

                    if serverManager.isProviderEnabled("kimi") {
                        HStack {
                            Text("K2.6 reasoning")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Toggle("", isOn: $k26ReasoningEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .tint(kimiEffortSelectionColor)
                                .labelsHidden()
                        }
                        .padding(.leading, 28)
                    }
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
        }
        .onDisappear {
            stopMonitoringAuthDirectory()
        }
        .alert("Authentication Result", isPresented: $showingAuthResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authResultMessage)
        }
        .alert("⚠️ MAX BUDGET MODE", isPresented: $showingMaxBudgetWarning) {
            Button("Engage", role: .cancel) { }
        } message: {
            Text("Opus 4.6 and Sonnet 4.6 requests will bypass their effort sliders and revert to classic extended thinking with maximum budget_tokens and effort=max. Opus 4.7 keeps its own slider — Max Budget Mode does not apply to it. These requests will burn through your quota fast.")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func advancedFactoryModelsNotice(_ providerName: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Advanced Factory models are on. Re-apply custom models to pick \(providerName) reasoning/thinking levels directly from Factory's model picker.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

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

    @ViewBuilder
    private func codexReasoningEffortRow(
        _ title: String,
        effortSelection: Binding<String>,
        fastMode: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(title) reasoning effort")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("Fast mode", isOn: fastMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Injects service_tier=priority for \(title) Responses API requests (Codex fast mode)")
            }
            Picker("", selection: effortSelection) {
                ForEach(["low", "medium", "high", "xhigh"], id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(codexEffortSelectionColor)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func effortPickerRow(_ title: String, selection: Binding<String>, options: [String], tint: Color = AccountRowView.accent, overrideBadge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let badge = overrideBadge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(Color(red: 0.9, green: 0.15, blue: 0.1))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color(red: 0.9, green: 0.15, blue: 0.1).opacity(0.5), lineWidth: 1)
                        )
                        .opacity(1.0)
                }
                Spacer()
            }
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(tint)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    /// A collapsible variant of `effortPickerRow` that shows only the title + current
    /// selection badge when collapsed. Tapping the header toggles the picker visibility.
    @ViewBuilder
    private func collapsibleEffortPickerRow(
        _ title: String,
        selection: Binding<String>,
        options: [String],
        tint: Color,
        isExpanded: Binding<Bool>,
        overrideBadge: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let badge = overrideBadge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundColor(Color(red: 0.9, green: 0.15, blue: 0.1))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(red: 0.9, green: 0.15, blue: 0.1).opacity(0.5), lineWidth: 1)
                            )
                    }
                    Spacer()
                    Text(selection.wrappedValue)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(tint.opacity(0.4), lineWidth: 1)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(selection.wrappedValue)
            .accessibilityHint(isExpanded.wrappedValue ? "Collapse effort picker" : "Expand effort picker")

            if isExpanded.wrappedValue {
                Picker("", selection: selection) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .tint(tint)
                .labelsHidden()
            }
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
    
    private func openAuthFolder() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
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
        let enabledModels = DroidProxyModelCatalog.settingsModels(advanced: factoryAdvancedModels).filter { model in
            guard let key = DroidProxyModelCatalog.providerKey(forSettingsModel: model) else { return true }
            return serverManager.isProviderEnabled(key)
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

        let enabledModels = DroidProxyModelCatalog.settingsModels(advanced: factoryAdvancedModels).filter { model in
            guard let key = DroidProxyModelCatalog.providerKey(forSettingsModel: model) else { return true }
            return serverManager.isProviderEnabled(key)
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
            let mode = factoryAdvancedModels ? "Advanced DroidProxy model entries" : "DroidProxy models"
            authResultMessage = "\(mode) added to Factory settings.\n\nRestart Factory (or open a new session) to see them in the model picker."
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
        var rendered = content
        if factoryAdvancedModels {
            rendered = rendered
                .replacingOccurrences(of: "model: custom:droidproxy:opus-4-7", with: "model: custom:droidproxy:opus-4-7-xhigh")
                .replacingOccurrences(of: "model: custom:droidproxy:gpt-5.2", with: "model: custom:droidproxy:gpt-5.2-high")
                .replacingOccurrences(of: "model: custom:droidproxy:gemini-3.1-pro", with: "model: custom:droidproxy:gemini-3.1-pro-high")
        }

        return rendered
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
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        
        let fileDescriptor = open(authDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )
        
        source.setEventHandler { [self] in
            // Debounce rapid file changes to prevent UI flashing
            pendingRefresh?.cancel()
            let workItem = DispatchWorkItem {
                NSLog("[FileMonitor] Auth directory changed - refreshing status")
                authManager.checkAuthStatus()
            }
            pendingRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.refreshDebounce, execute: workItem)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        fileMonitor = source
    }
    
    private func stopMonitoringAuthDirectory() {
        pendingRefresh?.cancel()
        fileMonitor?.cancel()
        fileMonitor = nil
    }
}
