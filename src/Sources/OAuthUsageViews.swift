import AppKit
import SwiftUI

/// Compact grid of per-account quota cards for the "OAuth Quota Usage" settings section.
struct OAuthUsageDashboard: View {
    let accounts: [OAuthAccountUsage]

    var body: some View {
        Group {
            if accounts.isEmpty {
                Text("Connect Codex, Claude, Grok, or Meta Muse OAuth accounts to show quota windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), spacing: 6, alignment: .top)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(accounts) { account in
                        OAuthUsageAccountCard(account: account, showHeader: showHeader(for: account.provider))
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// The email header only disambiguates when a provider has several
    /// accounts; a lone account is identified by its ring logos alone.
    private func showHeader(for provider: ServiceType) -> Bool {
        accounts.filter { $0.provider == provider }.count > 1
    }
}

struct OAuthUsageAccountCard: View {
    let account: OAuthAccountUsage
    let showHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showHeader {
                HStack(spacing: 4) {
                    if let iconName = usageIconName(for: account.provider),
                       let nsImage = IconCatalog.shared.image(
                        named: iconName,
                        resizedTo: NSSize(width: 11, height: 11),
                        template: true
                       ) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 11, height: 11)
                            .foregroundColor(.secondary)
                    }
                    Text(account.email)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help("\(account.provider.displayName) · \(account.email)")
            }

            if account.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: UsageRingGauge.diameter, height: UsageRingGauge.diameter + 12)
            } else if let error = account.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .help(error)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(account.windows) { window in
                        UsageRingGauge(window: window, provider: account.provider)
                    }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }
}

private func usageIconName(for provider: ServiceType) -> String? {
    switch provider {
    case .claude: return "icon-claude.png"
    case .codex: return "icon-codex.png"
    case .grok: return "icon-grok.svg"
    case .meta: return "icon-meta.svg"
    default: return nil
    }
}

/// Hollow ring whose stroke is the remaining quota; it drains clockwise from 12 o'clock.
/// The provider logo sits inside the ring, aspect-fit so it never clips or distorts;
/// the exact percent and reset time appear in an instant hover popover (`.help()`
/// tooltips inherit the multi-second system delay, which buries the numbers).
struct UsageRingGauge: View {
    static let diameter: CGFloat = 34
    /// Logo box: well inside the ~30.5pt clear inner diameter, with room to spare.
    static let logoLength: CGFloat = 20
    let window: OAuthUsageWindow
    let provider: ServiceType

    private var remaining: Double? { window.remainingPercent }

    private var tint: Color {
        ProviderUsageColors.color(for: provider)
    }

    private var logo: NSImage? {
        guard let iconName = usageIconName(for: provider) else { return nil }
        return IconCatalog.shared.image(
            named: iconName,
            resizedTo: NSSize(width: Self.logoLength, height: Self.logoLength),
            template: true
        )
    }

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: CGFloat((remaining ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: remaining)
                if let logo {
                    Image(nsImage: logo)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.logoLength, height: Self.logoLength)
                        .foregroundColor(tint)
                } else {
                    Text(remaining.map { "\(Int($0.rounded()))" } ?? "–")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            Text(window.title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .onHover { hovering in isHovering = hovering }
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            Text(helpText)
                .font(.system(size: 11))
                .padding(8)
        }
    }

    private var helpText: String {
        let usage = remaining.map { "\(Int($0.rounded()))% left" } ?? "Usage unavailable"
        guard let reset = window.resetText else { return "\(window.title): \(usage)" }
        return "\(window.title): \(usage)\nResets \(reset)"
    }
}
