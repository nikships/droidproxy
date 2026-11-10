import AppKit
import SwiftUI

/// Ring gauges for the "OAuth Quota Usage" settings section, flowing together
/// with no per-account boxes; a header only appears above a provider's rings
/// when it has several accounts to tell apart.
struct OAuthUsageDashboard: View {
    let accounts: [OAuthAccountUsage]
    /// Called after a gauge copies its usage `curl`, so the host window can confirm it.
    var onCopiedCurl: (OAuthAccountUsage) -> Void = { _ in }

    var body: some View {
        Group {
            if accounts.isEmpty {
                Text("Connect Codex, Claude, Grok, Meta Muse, or Antigravity OAuth accounts to show quota windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                FlowRowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(accounts) { account in
                        OAuthUsageAccountGroup(
                            account: account,
                            showHeader: showHeader(for: account.provider),
                            onCopiedCurl: { onCopiedCurl(account) }
                        )
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
    var onCopiedCurl: () -> Void = {}

    static let checkmarkDuration: TimeInterval = 1

    @State private var checkmark = TransientConfirmation<Bool>()

    private var copied: Bool { checkmark.value != nil }

    /// Shown under the hover text; clicking any gauge copies a `curl` that
    /// returns this account's live usage from ThinkingProxy.
    private var copyFootnote: String {
        copied ? "✓ curl copied" : "Click to copy a curl for this usage"
    }

    private func copyUsageCurl() {
        let command = UsageEndpoint.curlCommand(provider: account.provider, accountID: account.id)
        let didCopy = UsageCurlCopier.copy(command) {
            var token = 0
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { token = checkmark.show(true) }
            onCopiedCurl()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkmarkDuration) {
                withAnimation(.easeOut(duration: 0.2)) { checkmark.dismiss(token: token) }
            }
        }
        // A failed write has already cleared the pasteboard, so an earlier
        // click's checkmark would now be wrong.
        if !didCopy {
            withAnimation(.easeOut(duration: 0.2)) { checkmark.clear() }
        }
    }

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
                    .frame(width: DualUsageRingGauge.diameter, height: DualUsageRingGauge.diameter)
            } else if let error = account.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .help(error)
            } else if account.provider == .antigravity,
                      let pools = OAuthUsageTracker.antigravityPoolGroups(account.windows),
                      pools.count > 1 {
                // Each Antigravity model pool is its own dual gauge
                // (5-hour inside, Weekly outside), full size like every
                // other provider instead of a stack of half-size rings
                // where an exhausted pool's arc reads as nothing.
                // The whole row is one tap target for the account's curl.
                HStack(spacing: 12) {
                    ForEach(Array(pools.enumerated()), id: \.offset) { _, pool in
                        DualUsageRingGauge(
                            inner: pool[0],
                            outer: pool.count > 1 ? pool[1] : nil,
                            provider: account.provider,
                            footnote: copyFootnote
                        )
                        .overlay {
                            if copied { UsageCopiedCheckmark(diameter: DualUsageRingGauge.diameter) }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: copyUsageCurl)
            } else if account.windows.count > 2 {
                // Three or more windows (Claude's per-model buckets) fall
                // back to a compact stack so no limit is dropped.
                // The whole stack is one tap target for one account's curl,
                // so every ring in it confirms the copy.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(account.windows) { window in
                        UsageRingGauge(window: window, provider: account.provider, compact: true, footnote: copyFootnote)
                            .overlay {
                                if copied { UsageCopiedCheckmark(diameter: UsageRingGauge.compactDiameter) }
                            }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: copyUsageCurl)
            } else if let first = account.windows.first {
                DualUsageRingGauge(
                    inner: first,
                    outer: account.windows.count > 1 ? account.windows[1] : nil,
                    provider: account.provider,
                    footnote: copyFootnote
                )
                .overlay {
                    if copied { UsageCopiedCheckmark(diameter: DualUsageRingGauge.diameter) }
                }
                .contentShape(Circle())
                .onTapGesture(perform: copyUsageCurl)
            } else {
                EmptyView()
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
    case .antigravity: return "icon-gemini.png"
    default: return nil
    }
}

/// Writes a usage `curl` to the pasteboard and confirms only a write that
/// landed, since `setString` fails when another app takes ownership after
/// `clearContents()`.
enum UsageCurlCopier {
    @discardableResult
    static func copy(
        _ command: String,
        write: (String) -> Bool = writeToGeneralPasteboard,
        confirm: () -> Void
    ) -> Bool {
        guard write(command) else {
            NSLog("Usage curl copy failed: pasteboard rejected the write")
            return false
        }
        confirm()
        return true
    }

    static func writeToGeneralPasteboard(_ string: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(string, forType: .string)
    }
}

/// A briefly shown value whose delayed dismissal only applies to the latest
/// `show`, so a repeat click restarts the timer instead of being cut short by
/// an earlier click's dismissal.
struct TransientConfirmation<Value: Equatable>: Equatable {
    private(set) var value: Value?
    private var generation = 0

    /// Shows `value` and returns the token its dismissal must pass back.
    mutating func show(_ value: Value) -> Int {
        generation += 1
        self.value = value
        return generation
    }

    /// Clears the value unless a newer `show` happened after `token` was issued.
    mutating func dismiss(token: Int) {
        guard token == generation else { return }
        value = nil
    }

    /// Clears the value now and invalidates every pending dismissal.
    mutating func clear() {
        generation += 1
        value = nil
    }
}

/// Covers a gauge for a moment after its `curl` is copied.
struct UsageCopiedCheckmark: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
            Image(systemName: "checkmark")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: diameter, height: diameter)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
        .allowsHitTesting(false)
        .accessibilityLabel("Copied")
    }
}

/// Floating confirmation capsule for the Settings window.
struct CopiedToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(white: 0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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
    static let compactScale: CGFloat = 0.5
    static var compactDiameter: CGFloat { diameter * compactScale }
    /// Logo box: well inside the ~30.5pt clear inner diameter, with room to spare.
    static let logoLength: CGFloat = 20
    static let strokeWidth: CGFloat = 3.5
    let window: OAuthUsageWindow
    let provider: ServiceType
    var compact: Bool = false
    /// False when embedded in a dual gauge, which owns the combined popover.
    var showsPopover: Bool = true
    var footnote: String?

    private var remaining: Double? { window.remainingPercent }
    private var scale: CGFloat { compact ? Self.compactScale : 1 }

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
        usageHelpText(
            title: window.title,
            remaining: remaining,
            resetText: window.resetText,
            footnote: footnote
        )
    }
}

/// The one gauge every subscription renders: the shorter window keeps the
/// normal ring (with the logo) and the longer window wraps it in an outer
/// ring. Without a second limit the outer track stays permanently empty so
/// every gauge shares one size and placement. The popover lists real limits.
struct DualUsageRingGauge: View {
    static let gap: CGFloat = 2.5
    static let outerStroke: CGFloat = 3
    static var diameter: CGFloat {
        UsageRingGauge.diameter + (gap + outerStroke) * 2
    }
    let inner: OAuthUsageWindow
    let outer: OAuthUsageWindow?
    let provider: ServiceType
    var footnote: String?

    private var tint: Color {
        ProviderUsageColors.color(for: provider)
    }

    private var outerRemaining: Double? { outer?.remainingPercent }

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: Self.outerStroke)
            if outer != nil {
                Circle()
                    .trim(from: 0, to: CGFloat((outerRemaining ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.outerStroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: outerRemaining)
            }
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
        var parts = [usageHelpText(title: inner.title, remaining: inner.remainingPercent, resetText: inner.resetText)]
        if let outer {
            parts.append(usageHelpText(title: outer.title, remaining: outer.remainingPercent, resetText: outer.resetText))
        }
        if let footnote { parts.append(footnote) }
        return parts.joined(separator: "\n")
    }
}

private func usageHelpText(title: String, remaining: Double?, resetText: String?, footnote: String? = nil) -> String {
    let usage = remaining.map { "\(Int($0.rounded()))% left" } ?? "Usage unavailable"
    var text = "\(title): \(usage)"
    if let reset = resetText { text += "\nResets \(reset)" }
    if let footnote { text += "\n\(footnote)" }
    return text
}
