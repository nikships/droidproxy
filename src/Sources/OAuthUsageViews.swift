import AppKit
import SwiftUI

/// Ring gauges for the "OAuth Quota Usage" settings section, flowing together
/// with no per-account boxes; a header only appears above a provider's rings
/// when it has several accounts to tell apart.
struct OAuthUsageDashboard: View {
    let accounts: [OAuthAccountUsage]

    var body: some View {
        Group {
            if accounts.isEmpty {
                Text("Connect Codex, Claude, Grok, or Meta Muse OAuth accounts to show quota windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                FlowRowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(accounts) { account in
                        OAuthUsageAccountGroup(account: account, showHeader: showHeader(for: account.provider))
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

/// Wrapping left-to-right rows: account groups sit adjacent with no boxes,
/// spilling onto the next row when the window is too narrow.
struct FlowRowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        var rows: [Range<Int>] = []
        var start = 0
        var x: CGFloat = 0
        for i in subviews.indices {
            if i > start && x + sizes[i].width > bounds.width {
                rows.append(start..<i)
                start = i
                x = 0
            }
            x += sizes[i].width + horizontalSpacing
        }
        rows.append(start..<subviews.count)

        // Bottom-align within each row so ring rows line up even when a
        // headerless group shares the row with headed ones.
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var rx = bounds.minX
            for i in row {
                subviews[i].place(
                    at: CGPoint(x: rx, y: y + rowHeight - sizes[i].height),
                    proposal: ProposedViewSize(sizes[i])
                )
                rx += sizes[i].width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }
}

struct OAuthUsageAccountGroup: View {
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
                    .frame(width: UsageRingGauge.diameter, height: UsageRingGauge.diameter)
            } else if let error = account.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .help(error)
            } else if account.windows.count == 2 {
                // Two limits share one gauge: the shorter window keeps the
                // normal ring and the longer wraps it in an outer ring.
                DualUsageRingGauge(
                    inner: account.windows[0],
                    outer: account.windows[1],
                    provider: account.provider
                )
            } else if account.windows.count > 2 {
                // Three or more windows (only Claude's per-model buckets)
                // fall back to a compact stack so no limit is dropped.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(account.windows) { window in
                        UsageRingGauge(window: window, provider: account.provider, compact: true)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(account.windows) { window in
                        UsageRingGauge(window: window, provider: account.provider)
                    }
                }
            }
        }
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
/// Compact rings are exactly half size, for stacking 3+ windows when one
/// subscription has more limits than a dual gauge can show. No ring shows a
/// title; the popover names the window, so all text lives on hover.
struct UsageRingGauge: View {
    static let diameter: CGFloat = 34
    /// Logo box: well inside the ~30.5pt clear inner diameter, with room to spare.
    static let logoLength: CGFloat = 20
    static let strokeWidth: CGFloat = 3.5
    let window: OAuthUsageWindow
    let provider: ServiceType
    var compact: Bool = false
    /// False when embedded in a dual gauge, which owns the combined popover.
    var showsPopover: Bool = true

    private var remaining: Double? { window.remainingPercent }
    private var scale: CGFloat { compact ? 0.5 : 1 }

    private var tint: Color {
        ProviderUsageColors.color(for: provider)
    }

    private var logo: NSImage? {
        guard let iconName = usageIconName(for: provider) else { return nil }
        let length = Self.logoLength * scale
        return IconCatalog.shared.image(
            named: iconName,
            resizedTo: NSSize(width: length, height: length),
            template: true
        )
    }

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: Self.strokeWidth * scale)
            Circle()
                .trim(from: 0, to: CGFloat((remaining ?? 0) / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: Self.strokeWidth * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: remaining)
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.logoLength * scale, height: Self.logoLength * scale)
                    .foregroundColor(tint)
            } else {
                Text(remaining.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: Self.diameter * scale, height: Self.diameter * scale)
        .onHover { hovering in isHovering = hovering }
        .popover(isPresented: showsPopover ? $isHovering : .constant(false), arrowEdge: .bottom) {
            Text(helpText)
                .font(.system(size: 11))
                .padding(8)
        }
    }

    private var helpText: String {
        usageHelpText(title: window.title, remaining: remaining, resetText: window.resetText)
    }
}

/// One gauge for a two-limit subscription: the shorter window keeps the
/// normal ring (with the logo) and the longer window wraps it in an outer
/// ring. The hover popover lists both limits.
struct DualUsageRingGauge: View {
    static let gap: CGFloat = 2.5
    static let outerStroke: CGFloat = 3
    static var diameter: CGFloat {
        UsageRingGauge.diameter + (gap + outerStroke) * 2
    }
    let inner: OAuthUsageWindow
    let outer: OAuthUsageWindow
    let provider: ServiceType

    private var tint: Color {
        ProviderUsageColors.color(for: provider)
    }

    private var outerRemaining: Double? { outer.remainingPercent }

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: Self.outerStroke)
            Circle()
                .trim(from: 0, to: CGFloat((outerRemaining ?? 0) / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: Self.outerStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: outerRemaining)
            UsageRingGauge(window: inner, provider: provider, showsPopover: false)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .onHover { hovering in isHovering = hovering }
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            Text(helpText)
                .font(.system(size: 11))
                .padding(8)
        }
    }

    private var helpText: String {
        [
            usageHelpText(title: inner.title, remaining: inner.remainingPercent, resetText: inner.resetText),
            usageHelpText(title: outer.title, remaining: outer.remainingPercent, resetText: outer.resetText),
        ].joined(separator: "\n")
    }
}

private func usageHelpText(title: String, remaining: Double?, resetText: String?) -> String {
    let usage = remaining.map { "\(Int($0.rounded()))% left" } ?? "Usage unavailable"
    guard let reset = resetText else { return "\(title): \(usage)" }
    return "\(title): \(usage)\nResets \(reset)"
}
