import AppKit
import SwiftUI

/// Compact grid of per-account quota cards for the "OAuth Quota Usage" settings section.
struct OAuthUsageDashboard: View {
    let accounts: [OAuthAccountUsage]

    var body: some View {
        Group {
            if accounts.isEmpty {
                Text("Connect Codex, Claude, or Grok OAuth accounts to show quota windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), spacing: 6, alignment: .top)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(accounts) { account in
                        OAuthUsageAccountCard(account: account)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

struct OAuthUsageAccountCard: View {
    let account: OAuthAccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if let iconName = Self.iconName(for: account.provider),
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

    private static func iconName(for provider: ServiceType) -> String? {
        switch provider {
        case .claude: return "icon-claude.png"
        case .codex: return "icon-codex.png"
        case .grok: return "icon-grok.svg"
        default: return nil
        }
    }
}

/// Hollow ring whose stroke is the remaining quota; it drains clockwise from 12 o'clock.
struct UsageRingGauge: View {
    static let diameter: CGFloat = 34
    let window: OAuthUsageWindow
    let provider: ServiceType

    private var remaining: Double? { window.remainingPercent }

    private var tint: Color {
        ProviderUsageColors.color(for: provider)
    }

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
                Text(remaining.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: Self.diameter, height: Self.diameter)
            Text(window.title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .help(helpText)
    }

    private var helpText: String {
        let usage = remaining.map { "\(Int($0.rounded()))% left" } ?? "Usage unavailable"
        guard let reset = window.resetText else { return "\(window.title): \(usage)" }
        return "\(window.title): \(usage)\nResets \(reset)"
    }
}
