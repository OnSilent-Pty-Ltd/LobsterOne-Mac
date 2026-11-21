import AppKit
import SwiftUI

/// The Horizon palette for the popover and the app's windows. Every colour has a light and a
/// dark value and resolves against the view's appearance, so the popover follows the system.
/// Light: white ground, Sand cards, Lobster accent, Seagrass second colour. Dark: Ink ground,
/// Ember in place of Lobster.
enum PopoverPalette {
    static let backgroundNS = dynamic(light: 0xFFFFFF, dark: 0x1A1614)
    static let background = Color(nsColor: backgroundNS)
    /// Sand cards.
    static let card = color(light: 0xF5F0EA, dark: 0x26201C)
    /// Hover on a row inside a card.
    static let cardHover = color(light: 0xEFE8DF, dark: 0x3A322C)
    /// Hover on the popover ground (footer buttons).
    static let hover = color(light: 0xF5F0EA, dark: 0x26201C)
    static let divider = color(light: 0xEFE8DF, dark: 0x3A322C)
    /// Control borders (Line strong).
    static let lineStrong = color(light: 0xE6DED4, dark: 0x3A322C)
    static let text = color(light: 0x1A1614, dark: 0xFFFFFF)
    static let secondary = color(light: 0x6B625A, dark: 0xCFC6BC)
    static let tertiary = color(light: 0x6B625A, dark: 0x9A9088)
    static let brandNS = dynamic(light: 0xC84B20, dark: 0xF0834F)
    static let brand = Color(nsColor: brandNS)
    /// Lobster dark on Blush.
    static let brandText = color(light: 0xA83C17, dark: 0xF0834F)
    static let blush = color(light: 0xFCEEE7, dark: 0x3A2A22)
    static let primaryHover = color(light: 0xA83C17, dark: 0xF39B70)
    /// Text on a Lobster (or Ember) button.
    static let onBrand = color(light: 0xFFFFFF, dark: 0x1A1614)
    static let seagrass = color(light: 0x3F7D66, dark: 0x7FC4A8)
    /// Non-current bars in the spend chart.
    static let bar = color(light: 0xF0B9A0, dark: 0x8A4A2E)
    static let track = color(light: 0xE6DED4, dark: 0x3A322C)
    static let logo = color(light: 0x0A0A0A, dark: 0xFFFFFF)
    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.10) : NSColor(hex: 0x1A1614).withAlphaComponent(0.10)
    })
    // Status: errors and destructive actions only.
    static let criticalNS = dynamic(light: 0xA32A1D, dark: 0xFF9A8C)
    static let critical = Color(nsColor: criticalNS)
    static let criticalText = critical
    static let criticalBackground = color(light: 0xFBE5E1, dark: 0x3D2320)
    static let warningText = color(light: 0x8A5A00, dark: 0xE6B95C)
    static let warningBackground = color(light: 0xFBEFD2, dark: 0x3A2F17)
    /// Success always comes with a tick.
    static let successText = color(light: 0x2F6B3A, dark: 0x7BC88A)
    static let successBackground = color(light: 0xE6F1E6, dark: 0x1F2E22)
    // Tool status dots.
    static let dotActive = successText
    static let dotWaiting = warningText
    static let dotOff = color(light: 0x6B625A, dark: 0x9A9088)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { isDark($0) ? NSColor(hex: dark) : NSColor(hex: light) }
    }

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamic(light: light, dark: dark))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The status item popover. Observes StatusBarController's published state directly, so it
/// refreshes itself whenever polling updates quota, burn or sources.
struct MenuPopoverView: View {
    @ObservedObject var controller: StatusBarController
    @State private var hoveredDay: Int?
    @AppStorage("screensaverInviteDismissed") private var screensaverInviteDismissed = false
    @State private var screensaverJustInstalled = false
    @State private var screensaverInstallError: String?
    @AppStorage("popoverPage") private var page: PopoverPage = .claude
    @AppStorage(TeamMonitor.enabledKey) private var teamEnabled = true

    static let width: CGFloat = 344
    private let hPad: CGFloat = 16

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(width: Self.width)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
        .background(shortcuts)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = controller.bannerText {
                noticeBanner(text)
            }
            header(now: now)

            if pages.count > 1 {
                PopoverPageSwitch(page: $page, pages: pages)
                    .padding(.horizontal, hPad)
            }

            if let monitor = awsMonitor, page == .aws {
                AWSCostsView(monitor: monitor, now: now, perform: controller.perform,
                             note: controller.awsNote)
            } else if showsTeam {
                TeamView(monitor: controller.teamMonitor, calendar: controller.calendarMonitor, weekTokens: controller.sevenDayBurn?.totalTokens,
                         now: now, perform: controller.perform)
            } else {
                claudePage(now: now)
            }

            footer
        }
        .padding(.top, 16)
        .onChange(of: page) { _, page in
            if page == .aws, let monitor = awsMonitor { Task { await monitor.menuOpened() } }
            if page == .team, teamEnabled { Task { await controller.teamMonitor.menuOpened() } }
        }
    }

    /// Code always; Team while its hidden switch is on; Infra once AWS is connected.
    private var pages: [PopoverPage] {
        [.claude] + (teamEnabled ? [.team] : []) + (awsMonitor != nil ? [.aws] : [])
    }

    private var showsTeam: Bool { teamEnabled && page == .team }

    private var refreshAction: StatusBarController.PopoverAction {
        showsAWS ? .refreshCosts : showsTeam ? .refreshTeam : .refresh
    }

    /// The page is a choice only once AWS is connected; until then the popover is the Claude page.
    private var awsMonitor: CostMonitor? {
        controller.awsConnected ? controller.costMonitor : nil
    }

    private var showsAWS: Bool { awsMonitor != nil && page == .aws }

    @ViewBuilder
    private func claudePage(now: Date) -> some View {
        ForEach(controller.townInvites.filter { $0.isLive(at: now) }) { invite in
            townInviteRow(invite)
        }

        if let anth = realQuota {
            quotaRings(anth, now: now)
            if anth.extraUsageEnabled, let used = anth.usedCredits, let limit = anth.monthlyLimit, limit > 0 {
                creditsCard(used: used, limit: limit)
            }
        }

        if let burn = controller.sevenDayBurn, burn.totalTokens > 0 {
            spendCard(burn, now: now)
        }

        if !controller.sourceStatuses.isEmpty {
            toolChips
        }

        if showScreensaverInvite {
            screensaverInvite
        }
    }

    private var realQuota: AnthropicQuotaState? {
        guard let anth = controller.quotaState.anthropicState, anth.source == .oauthAPI else { return nil }
        guard anth.fiveHourPct != nil || anth.sevenDayPct != nil else { return nil }
        return anth
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ClawMark(size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("LobsterOne")
                    .font(BrandFonts.sans(17, weight: .bold))
                    .tracking(-0.03 * 17)
                Text(freshnessText(now: now))
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            Spacer()
            if let plan = planText {
                Text(plan)
                    .font(BrandFonts.sans(12, weight: .semibold))
                    .foregroundStyle(PopoverPalette.brandText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(PopoverPalette.blush, in: Capsule())
            }
        }
        .padding(.horizontal, hPad)
    }

    private var planText: String? {
        let q = controller.quotaState
        if q.isOffline && !q.offlineReason.isEmpty { return "Offline" }
        if let label = q.anthropicState?.planLabel { return label }
        if q.planTier.isEmpty { return nil }
        return q.displayPlanTier
    }

    private func freshnessText(now: Date) -> String {
        let q = controller.quotaState
        if q.isOffline && !q.offlineReason.isEmpty { return q.offlineReason }
        if q.planTier.isEmpty && controller.sourceStatuses.isEmpty { return "Not connected" }
        let seconds = Int(now.timeIntervalSince(q.lastUpdated))
        if seconds < 60 { return "Updated just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "Updated \(minutes)m ago" }
        return "Updated \(minutes / 60)h ago"
    }

    // MARK: - Screensaver invite

    /// Shown until the screensaver is installed or the invite is dismissed, and only on builds
    /// that carry the screensaver.
    private var showScreensaverInvite: Bool {
        !screensaverInviteDismissed && !screensaverJustInstalled
            && !ScreensaverWatch.isInstalled && ScreensaverInstaller.bundledURL != nil
    }

    private var screensaverInvite: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Try the screensaver")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text("Your usage, live on screen while your Mac is idle. Four styles to pick from.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    do {
                        try ScreensaverInstaller.install()
                        screensaverJustInstalled = true
                        ScreensaverInstaller.openScreenSaverSettings()
                    } catch {
                        screensaverInstallError = error.localizedDescription
                    }
                } label: {
                    Text("Install")
                        .font(BrandFonts.sans(13, weight: .semibold))
                        .foregroundStyle(PopoverPalette.onBrand)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(PopoverPalette.brand, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { screensaverInviteDismissed = true } label: {
                    Text("Not now")
                        .font(BrandFonts.sans(13, weight: .medium))
                        .foregroundStyle(PopoverPalette.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if let screensaverInstallError {
                Text(screensaverInstallError)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.criticalText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, hPad)
    }

    // MARK: - Banners

    private func noticeBanner(_ text: String) -> some View {
        Button { controller.perform(.banner) } label: {
            HStack(spacing: 10) {
                Image(systemName: controller.clientPolicy.level == .soft ? "arrow.down.circle" : "bell")
                    .font(.system(size: 14, weight: .medium))
                Text(text).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .font(BrandFonts.sans(13.5, weight: .medium))
            .foregroundStyle(PopoverPalette.brandText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PopoverPalette.blush, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, hPad)
    }

    /// "<Name> wants to chat in town · Join". The whole row joins, like the notice banner.
    private func townInviteRow(_ invite: TownInvite) -> some View {
        Button { controller.perform(.joinTown(inviteId: invite.inviteId)) } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PopoverPalette.brandText)
                (Text(invite.rowText)
                    + Text(" · ").foregroundColor(PopoverPalette.secondary)
                    + Text("Join").fontWeight(.semibold).foregroundColor(PopoverPalette.brandText))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
            }
            .font(BrandFonts.sans(13.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(invite.notificationBody)
        .padding(.horizontal, hPad)
    }

    // MARK: - Quota rings

    /// The two limits side by side. A limit that will run out before it resets says so on its own
    /// ring, so warnings never stack above the page.
    private func quotaRings(_ anth: AnthropicQuotaState, now: Date) -> some View {
        let session = anth.fiveHourPct.flatMap { pct in
            anth.fiveHourResetsAt.flatMap { SessionPace.warning(percent: pct, resetsAt: $0, now: now) }
        }
        let week = anth.sevenDayPct.flatMap { pct in
            anth.sevenDayResetsAt.flatMap { SessionPace.warning(percent: pct, resetsAt: $0, now: now, limit: .week) }
        }
        return HStack(alignment: .top, spacing: 10) {
            if let pct = anth.fiveHourPct {
                QuotaRingCard(title: "Session", percent: pct, accent: PopoverPalette.brand, warning: session, limit: .session,
                         caption: controller.formatResetTime(anth.fiveHourResetsAt, now: now))
            }
            if let pct = anth.sevenDayPct {
                QuotaRingCard(title: "Week", percent: pct, accent: PopoverPalette.seagrass, warning: week, limit: .week,
                         caption: controller.formatResetTime(anth.sevenDayResetsAt, now: now))
            }
        }
        // Both cards take the height of the taller one, so one warning does not leave them uneven.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, hPad)
    }

    /// The whole warning as a sentence, for the tooltip and for VoiceOver.
    static func paceSentence(_ warning: SessionPace.Warning, limit: SessionPace.Limit) -> String {
        "At this pace you'll hit the \(limit == .session ? "session" : "weekly") cap in about \(duration(minutes: warning.minutesToCap)), \(duration(minutes: warning.minutesCappedBeforeReset)) before it resets."
    }

    /// The warning in the two short lines a ring card has room for.
    static func paceLines(_ warning: SessionPace.Warning) -> (cap: String, gap: String) {
        ("Cap in \(duration(minutes: warning.minutesToCap))", "\(duration(minutes: warning.minutesCappedBeforeReset)) before reset")
    }

    private func creditsCard(used: Double, limit: Double) -> some View {
        let pct = min(max(used / limit, 0), 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Extra usage").font(BrandFonts.sans(14, weight: .medium))
                Spacer()
                Text("$\(Self.dollars(used)) / $\(Self.dollars(limit))")
                    .font(BrandFonts.sans(13))
                    .monospacedDigit()
                    .foregroundStyle(PopoverPalette.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PopoverPalette.track)
                    Capsule().fill(pct >= 0.8 ? PopoverPalette.critical : PopoverPalette.brand)
                        .frame(width: max(geo.size.width * pct, pct > 0 ? 6 : 0))
                }
            }
            .frame(height: 6)
        }
        .padding(14)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, hPad)
    }

    // MARK: - Spend

    private func spendCard(_ burn: SevenDayBurn, now: Date) -> some View {
        let hovered = hoveredDay.flatMap { burn.days.indices.contains($0) ? burn.days[$0] : nil }
        let maxBar = max(burn.bars.max() ?? 0, 1)
        let lastIndex = burn.bars.count - 1

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hovered?.longLabel ?? "Last 7 days")
                    .font(BrandFonts.sans(14))
                    .foregroundStyle(PopoverPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                // The figures keep their full width; the label gives way before they wrap.
                Text("$\(Self.dollars(hovered?.costUsd ?? burn.costUsd))")
                    .font(BrandFonts.sans(25, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text("\(SevenDayBurn.formatTokens(hovered?.tokens ?? burn.totalTokens)) tok")
                    .font(BrandFonts.sans(13))
                    .foregroundStyle(PopoverPalette.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(burn.bars.enumerated()), id: \.offset) { i, value in
                    let emphasised = hoveredDay == i || (hoveredDay == nil && i == lastIndex)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(value == 0 ? PopoverPalette.track : (emphasised ? PopoverPalette.brand : PopoverPalette.bar))
                        .frame(height: max(3, 56 * CGFloat(value) / CGFloat(maxBar)))
                        .frame(maxWidth: .infinity, maxHeight: 56, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hoveredDay = i } else if hoveredDay == i { hoveredDay = nil }
                        }
                }
            }
            .frame(height: 56)
            .padding(.top, 12)

            if burn.days.count == burn.bars.count {
                HStack(spacing: 6) {
                    ForEach(Array(burn.days.enumerated()), id: \.offset) { i, day in
                        let isToday = i == lastIndex && day.isToday(now: now)
                        Text(isToday ? "Today" : day.weekdayInitial)
                            .font(BrandFonts.sans(12, weight: i == lastIndex ? .semibold : .regular))
                            .foregroundStyle(i == lastIndex ? PopoverPalette.text : PopoverPalette.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 6)
            }

            Text("Excludes cached input tokens.")
                .font(BrandFonts.sans(12))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.top, 10)
        }
        .padding(14)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, hPad)
    }

    // MARK: - Tools

    private var toolChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(controller.sourceStatuses) { source in
                HStack(spacing: 7) {
                    Circle().fill(dotColor(source.statusLevel)).frame(width: 8, height: 8)
                    Text(source.displayName).font(BrandFonts.sans(14, weight: .medium))
                    if let detail = chipDetail(source) {
                        Text(detail)
                            .font(BrandFonts.sans(12.5))
                            .monospacedDigit()
                            .foregroundStyle(PopoverPalette.secondary)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .background(PopoverPalette.card, in: Capsule())
                .help(Self.chipHelp(source))
            }
        }
        .padding(.horizontal, hPad)
    }

    /// Claude Code's quota already shows in the rings, so its chip only repeats a percentage
    /// when no real quota is available. Other tools (Codex) show their own rate-limit %.
    /// The status needs no word, the dot says it; hovering the chip spells it out.
    private func chipDetail(_ source: SourceStatus) -> String? {
        let pct = controller.displayPercent(for: source)
        let showsPct = pct > 0 && !(source.id == "claude-code" && realQuota?.fiveHourPct != nil)
        return showsPct ? "\(Int(pct.rounded()))%" : nil
    }

    /// The chip's tooltip: the status in a word, then when the tool was last seen.
    static func chipHelp(_ source: SourceStatus) -> String {
        let seen = source.lastSeenText
        switch source.statusLevel {
        case .active: return "Active. \(seen)"
        case .waiting: return seen.hasPrefix("Last seen") ? "Waiting. \(seen)" : seen
        case .disconnected: return "Off"
        }
    }

    private func dotColor(_ level: SourceStatus.StatusLevel) -> Color {
        switch level {
        case .active: PopoverPalette.dotActive
        case .waiting: PopoverPalette.dotWaiting
        case .disconnected: PopoverPalette.dotOff
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            HStack(spacing: 2) {
                FooterButton(help: "Open Dashboard (⌘D)") { controller.perform(.dashboard) } label: {
                    HStack(spacing: 8) {
                        LineGlyph(data: HorizonGlyphs.openExternal)
                        Text("Open Dashboard")
                            .font(BrandFonts.sans(14, weight: .semibold))
                    }
                    .foregroundStyle(PopoverPalette.text)
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                }
                Spacer()
                FooterButton(help: "Refresh (⌘R)") { controller.perform(refreshAction) } label: {
                    LineGlyph(data: HorizonGlyphs.refresh).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Refresh")
                FooterButton(help: "Settings (⌘,)") { controller.perform(.settings) } label: {
                    LineGlyph(data: HorizonGlyphs.sliders).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
                Menu {
                    Button("Diagnostics & Logs") { controller.perform(.diagnostics) }
                    Button("Check for Updates…") { controller.perform(.checkForUpdates) }
                    Divider()
                    Button("Sign Out") { controller.perform(.signOut) }
                    Button("Quit LobsterOne") { controller.perform(.quit) }
                } label: {
                    Image(nsImage: Self.moreImage)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .help("Diagnostics, updates, sign out, quit")
                .accessibilityLabel("More")
            }
            .foregroundStyle(PopoverPalette.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    /// The menu button draws its label through AppKit, so the glyph goes in as a template image.
    private static let moreImage = HorizonGlyphs.templateImage(
        HorizonGlyphs.more, viewBox: 24, size: 17, lineWidth: 1.8, description: "More")

    /// Invisible buttons so the popover keeps the old menu's key equivalents.
    private var shortcuts: some View {
        ZStack {
            Button("") { controller.perform(refreshAction) }.keyboardShortcut("r")
            if pages.count > 1 {
                ForEach(Array(pages.enumerated()), id: \.element) { index, value in
                    Button("") { page = value }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
            Button("") { controller.perform(.dashboard) }.keyboardShortcut("d")
            Button("") { controller.perform(.settings) }.keyboardShortcut(",")
            Button("") { controller.perform(.quit) }.keyboardShortcut("q")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Formatting

    static func duration(minutes: Int) -> String {
        if minutes >= 24 * 60 {
            let d = minutes / (24 * 60), h = (minutes % (24 * 60) + 30) / 60
            if h == 24 { return "\(d + 1)d" }
            return h == 0 ? "\(d)d" : "\(d)d \(h)h"
        }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func dollars(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

/// Plain button with a soft hover fill, used across the footer.
private struct FooterButton<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .background(hovering ? PopoverPalette.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Left-to-right wrapping layout for the tool chips (a third tool must not overflow the width).
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(indices: [i], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(i)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Session takes Lobster, Week takes Seagrass; either turns red from 80%. When it resets
/// is the card's tooltip, not a line on it. A pace warning sits under the title.
struct QuotaRingCard: View {
    let title: String
    let percent: Double
    let accent: Color
    /// Set when the limit will run out before it resets.
    let warning: SessionPace.Warning?
    let limit: SessionPace.Limit
    /// "resets in 3h 12m".
    let caption: String?

    var body: some View {
        let critical = percent >= 80
        let clamped = min(max(percent, 0), 100)
        let sentence = warning.map { MenuPopoverView.paceSentence($0, limit: limit) }
        let resets = caption.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
        return VStack(spacing: 0) {
            ZStack {
                Circle().stroke(PopoverPalette.track, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: clamped / 100)
                    .stroke(critical ? PopoverPalette.critical : accent,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(percent.rounded()))")
                        .font(BrandFonts.sans(28, weight: .semibold))
                    Text("%")
                        .font(BrandFonts.sans(13, weight: .semibold))
                        .foregroundStyle(PopoverPalette.secondary)
                }
            }
            .padding(4.5)
            .frame(width: 78, height: 78)

            Text(title)
                .font(BrandFonts.sans(15, weight: .semibold))
                .padding(.top, 10)
            if let warning {
                let lines = MenuPopoverView.paceLines(warning)
                HStack(spacing: 4) {
                    LineGlyph(data: HorizonGlyphs.warning, size: 13, lineWidth: 2)
                    Text(lines.cap).font(BrandFonts.sans(12.5, weight: .semibold))
                }
                .foregroundStyle(PopoverPalette.criticalText)
                .padding(.top, 5)
                Text(lines.gap)
                    .font(BrandFonts.sans(11.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .padding(.top, 1)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .padding(.horizontal, 8)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .help([sentence, resets].compactMap { $0 }.joined(separator: " "))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(["\(title) \(Int(percent.rounded())) percent used.", resets, sentence].compactMap { $0 }.joined(separator: " "))
    }
}
