import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, ObservableObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var showingBlockScreen = false
    @Published var quotaState: QuotaState = .empty
    @Published var sourceStatuses: [SourceStatus] = []
    @Published var unreadNotificationCount: Int = 0
    @Published var clientPolicy: ClientPolicy = .okDefault
    @Published var sevenDayBurn: SevenDayBurn?
    /// Open invites into the harbour town, one popover row each.
    @Published var townInvites: [TownInvite] = []
    /// Unread count captured when the popover opened. The live count is cleared on open (the
    /// menu bar badge goes away) but the banner should stay visible while the popover is up.
    @Published private(set) var bannerUnreadCount: Int = 0
    /// AWS costs, once connected: the popover gains its AWS page.
    @Published var awsConnected = false
    var costMonitor: CostMonitor?
    /// The crew, for the popover's Team page.
    let teamMonitor = TeamMonitor()
    /// The crew's calendar: jobs set for a day and time, and what came of each.
    let calendarMonitor = CrewCalendarMonitor()
    private var crewWatcher: CrewWatcher?
    private var crewSubscriptions: Set<AnyCancellable> = []
    /// Shows a dot in the menu bar while a crew member needs attention.
    static let crewInMenuBarKey = "crewInMenuBar"
    /// Said on the AWS page when the list may not be the whole bill.
    @Published var awsNote: String?
    /// How many logins a refresh reads through; each is one billed request.
    @Published var awsLoginCount = 1
    /// Adds this month's AWS total to the menu bar title (on unless switched off in Settings).
    var costInMenuBar = false

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // No appearance observer here. macOS changes the button's appearance each time it
            // snapshots the item for another menu bar, so reacting by setting a new image made
            // it snapshot again: an endless loop at 100% CPU. The glyphs pick their colours at
            // draw time instead (see ringGlyph).
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover

        updateDisplay()
        buildMenu()
        startCrew()
    }

    /// Watches the crew's files and keeps the menu bar in step, while the Team page is switched on.
    private func startCrew() {
        guard TeamMonitor.isEnabled() else { return }
        teamMonitor.onNewAttention = { CrewNotifier.announce($0) }
        teamMonitor.$unnoticed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
            .store(in: &crewSubscriptions)
        let watcher = CrewWatcher(monitor: teamMonitor)
        watcher.start()
        crewWatcher = watcher
        // A job that asks first is announced when due; one that starts by itself is announced when it has finished.
        calendarMonitor.onDue = { [weak self] due in
            CrewJobNotifier.announce(due, members: self?.teamMonitor.snapshot?.members ?? [])
        }
        calendarMonitor.onFinished = { [weak self] job, run in
            CrewJobNotifier.finished(job, run, members: self?.teamMonitor.snapshot?.members ?? [])
        }
        calendarMonitor.start()
        NotificationCenter.default.publisher(for: CrewJobNotifier.answered)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let key = note.userInfo?["key"] as? String else { return }
                if note.userInfo?["run"] as? Bool == true {
                    Task { await self.calendarMonitor.run(key: key) }
                } else {
                    CrewCalendarWindow.shared.show(calendar: self.calendarMonitor, team: self.teamMonitor)
                }
            }
            .store(in: &crewSubscriptions)
        Task { await teamMonitor.checkCrew() }
    }

    func updateDisplay() {
        guard let button = statusItem?.button else { return }

        if clientPolicy.level == .block {
            // One of the two states that take colour: the warning sign in the error red.
            let warning = HorizonGlyphs.image(HorizonGlyphs.warning, viewBox: 24, size: 16, lineWidth: 2) {
                PopoverPalette.criticalNS // dynamic: resolves for the bar it's drawn on
            }
            warning.accessibilityDescription = "Update required"
            button.image = warning
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let maxPercent = sourceStatuses.map { displayPercent(for: $0) }.max()

        // The glyph is the button's own image, not a text attachment: the menu bar only tints
        // a template image it draws itself, so an attached ring stayed black on a dark bar.
        // With no quota to show, the claw stands in for the ring.
        if let pct = maxPercent {
            button.image = Self.ringGlyph(percent: pct)
        } else {
            button.image = HorizonGlyphs.templateImage(HorizonGlyphs.claw, viewBox: 40, size: 15, description: "LobsterOne")
        }
        button.imagePosition = .imageLeading

        let font: [NSAttributedString.Key: Any] = [
            .font: BrandFonts.nsSans(13, weight: .medium, tabular: true),
        ]

        let attributedString = NSMutableAttributedString(string: " ", attributes: font)

        if let pct = maxPercent, pct > 0 || !sourceStatuses.isEmpty {
            let prefix = quotaState.isRealQuota ? "" : "~"
            attributedString.append(NSAttributedString(string: "\(prefix)\(Int(pct.rounded()))% · ", attributes: font))
        }

        attributedString.append(NSAttributedString(string: quotaState.menuBarText, attributes: font))

        if costInMenuBar, awsConnected, let monitor = costMonitor, let total = monitor.monthToDateTotal {
            let figure = CostFormat.short(total, currency: monitor.snapshot?.currency)
            attributedString.append(NSAttributedString(string: " · \(figure)", attributes: font))
        }

        if unreadNotificationCount > 0 {
            let badgeAttachment = NSTextAttachment()
            badgeAttachment.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Notifications")
            badgeAttachment.image?.isTemplate = true
            let badgeText = unreadNotificationCount > 99 ? "99+" : "\(unreadNotificationCount)"
            attributedString.append(NSAttributedString(string: " · ", attributes: font))
            attributedString.append(NSAttributedString(attachment: badgeAttachment))
            attributedString.append(NSAttributedString(string: badgeText, attributes: font))
        }

        if let dot = crewGlyph() {
            let attachment = NSTextAttachment()
            attachment.image = dot
            // Sits on the text's centre line, not its baseline.
            attachment.bounds = NSRect(x: 0, y: 1.5, width: dot.size.width, height: dot.size.height)
            attributedString.append(NSAttributedString(string: " ", attributes: font))
            attributedString.append(NSAttributedString(attachment: attachment))
        }

        button.attributedTitle = attributedString
        button.toolTip = "Today's token usage: input + output. Cached input is excluded, so this reads lower than the in-session \"used\" figure Codex and Claude Code show in their status lines."
    }

    /// The popover content is SwiftUI bound to the published state above, so it redraws itself.
    /// This only switches between the normal view and the forced-update screen. The name is kept
    /// so the polling callbacks in LobsterOneApp don't need to change.
    func buildMenu() {
        guard let popover else { return }
        let wantsBlock = clientPolicy.level == .block
        if wantsBlock {
            let view = BlockPopoverView(message: clientPolicy.message ?? "")
            view.onDownload = { [weak self] in
                guard let url = self?.clientPolicy.downloadUrl else { return }
                self?.onPolicyDownload?(url)
            }
            view.onQuit = { [weak self] in self?.onQuit?() }
            let vc = NSViewController()
            vc.view = view
            popover.contentViewController = vc
            showingBlockScreen = true
        } else if showingBlockScreen || popover.contentViewController == nil {
            let host = NSHostingController(rootView: MenuPopoverView(controller: self))
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            showingBlockScreen = false
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    var isPopoverShown: Bool { popover?.isShown ?? false }

    func showPopover() {
        guard let popover, let button = statusItem?.button, !popover.isShown else { return }
        buildMenu()
        bannerUnreadCount = unreadNotificationCount
        if unreadNotificationCount > 0 {
            unreadNotificationCount = 0
            updateDisplay()
        }
        // The AWS page asks for fresh figures on open; the monitor keeps that to once an hour.
        if awsConnected, let monitor = costMonitor,
           UserDefaults.standard.string(forKey: "popoverPage") == PopoverPage.aws.rawValue {
            Task { await monitor.menuOpened() }
        }
        if TeamMonitor.isEnabled() {
            // A dot in the menu bar leads to the Team page; opening it is the look that clears the dot.
            if !teamMonitor.unnoticed.isEmpty {
                UserDefaults.standard.set(PopoverPage.team.rawValue, forKey: "popoverPage")
                teamMonitor.markNoticed()
            }
            if UserDefaults.standard.string(forKey: "popoverPage") == PopoverPage.team.rawValue {
                Task { await teamMonitor.menuOpened() }
            }
        }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        tintPopoverFrame()
    }

    /// NSPopover draws its own material behind the content and the arrow. Paint the frame view
    /// in the content background so the arrow matches instead of showing a grey notch.
    private func tintPopoverFrame() {
        guard let view = popover?.contentViewController?.view,
              let frameView = view.window?.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = Self.resolved(PopoverPalette.backgroundNS, in: view.effectiveAppearance).cgColor
    }

    /// A dynamic colour as it looks in the given appearance (layers and images keep a fixed colour).
    static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: color.cgColor) ?? color
        }
        return result
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.bannerUnreadCount = 0 }
    }

    var onSignOut: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onRefreshNow: (() -> Void)?
    var onShowDiagnostics: (() -> Void)?
    var onShowAWSSettings: (() -> Void)?
    var onNotificationsViewed: (() -> Void)?
    /// Join from a town invite row: AppDelegate opens the town in the browser.
    var onJoinTown: ((String) -> Void)?
    /// Invoked when the user clicks "Download Now" from soft-nudge banner or block popover.
    /// AppDelegate opens the URL in the default browser.
    var onPolicyDownload: ((String) -> Void)?

    enum PopoverAction: Equatable {
        case dashboard, refresh, settings, diagnostics, checkForUpdates, signOut, quit, banner
        case joinTown(inviteId: String)
        /// Refresh on the AWS page. Each request is billed, so a press within five minutes
        /// of the last does nothing.
        case refreshCosts
        /// Refresh on the Team page: reads the crew's files again.
        case refreshTeam
        /// Opens the hiring window.
        case hireCrew
        /// Removes a crew member the app hired; the popover stays open.
        case removeCrew(String)
        /// Opens the window showing what changed in a member's charter and notebook.
        case crewChanges(String)
        /// Opens the latest digest.
        case crewDigest
        /// Opens the crew's calendar.
        case crewCalendar
        case awsSettings
        case openURL(URL)
    }

    /// Everything except Refresh closes the popover first, so windows and the browser
    /// open in front instead of behind a still-open popover.
    func perform(_ action: PopoverAction) {
        let staysOpen: Bool = switch action {
        case .refresh, .refreshCosts, .refreshTeam, .removeCrew: true
        default: false
        }
        if !staysOpen { popover?.performClose(nil) }
        switch action {
        case .dashboard: NSWorkspace.shared.open(URL(string: "\(Constants.appURL)/dashboard")!)
        case .refresh: onRefreshNow?()
        case .settings: onSettings?()
        case .diagnostics: onShowDiagnostics?()
        case .checkForUpdates: onCheckForUpdates?()
        case .signOut: onSignOut?()
        case .quit: onQuit?()
        case .joinTown(let inviteId): onJoinTown?(inviteId)
        case .refreshCosts:
            if let monitor = costMonitor {
                Task { await monitor.refresh(ifOlderThan: AWSCostService.manualRefreshInterval) }
            }
        case .refreshTeam: Task { await teamMonitor.refresh() }
        case .hireCrew:
            CrewWindow.shared.show { [weak self] in
                Task { await self?.teamMonitor.refresh() }
            }
        case .crewChanges(let name):
            CrewChangesWindow.shared.show(member: name, monitor: teamMonitor)
        case .crewDigest:
            CrewDigestWindow.shared.show(monitor: teamMonitor)
        case .crewCalendar:
            CrewCalendarWindow.shared.show(calendar: calendarMonitor, team: teamMonitor)
        case .removeCrew(let name):
            do {
                try CrewInstaller().remove(agentNamed: name)
            } catch {
                DebugLog.shared.log("Crew: could not remove \(name): \(error.localizedDescription)")
            }
            Task { await teamMonitor.refresh() }
        case .awsSettings: onShowAWSSettings?()
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .banner:
            if clientPolicy.level == .soft, let url = clientPolicy.downloadUrl {
                onPolicyDownload?(url)
            } else {
                NSWorkspace.shared.open(URL(string: "\(Constants.appURL)/notifications")!)
                onNotificationsViewed?()
            }
        }
    }

    /// Soft update nudge wins over notifications; nil hides the banner.
    var bannerText: String? {
        if clientPolicy.level == .soft, let m = clientPolicy.message, !m.isEmpty { return m }
        let count = bannerUnreadCount
        guard count > 0 else { return nil }
        return count == 1 ? "You have 1 new notification" : "You have \(count) new notifications"
    }

    // MARK: - Crew in the menu bar

    /// An orange dot while a crew member needs attention and the popover has not been opened since.
    /// Nil when all is quiet, the Team page is off, or the dot is switched off.
    private func crewGlyph() -> NSImage? {
        let defaults = UserDefaults.standard
        guard TeamMonitor.isEnabled(defaults),
              defaults.object(forKey: Self.crewInMenuBarKey) as? Bool ?? true else { return nil }
        let members = Set(teamMonitor.unnoticed.map(\.member))
        return members.isEmpty ? nil : CrewMenuBarGlyph.dot(count: members.count)
    }

    // MARK: - Menu bar glyph

    /// Ring that fills with the highest tool percentage. Below 80% it is a template image, so the
    /// menu bar tints it; from 80% the arc turns the error red (the track still follows the bar).
    /// The colours are dynamic and picked inside the drawing handler, which runs under the
    /// appearance of whichever menu bar is drawing, so nothing has to watch for light/dark flips.
    static func ringGlyph(percent: Double) -> NSImage {
        let critical = percent >= 80
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let arcColor: NSColor = critical ? PopoverPalette.criticalNS : .black
            let trackColor = (critical ? NSColor.labelColor : .black).withAlphaComponent(0.3)
            let lineWidth: CGFloat = 2.4
            let ringRect = rect.insetBy(dx: 2, dy: 2) // radius 6, as on the board
            let track = NSBezierPath(ovalIn: ringRect)
            track.lineWidth = lineWidth
            trackColor.setStroke()
            track.stroke()

            let fraction = min(max(percent, 0), 100) / 100
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: NSPoint(x: rect.midX, y: rect.midY),
                    radius: ringRect.width / 2,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arcColor.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = !critical
        image.accessibilityDescription = "LobsterOne, \(Int(percent.rounded())) percent used"
        return image
    }

    // MARK: - Helpers

    /// The percentage to display for a source. For Claude Code, prefer the real
    /// Anthropic 5h utilization (the same source the quota rings use) when available,
    /// so the tool chip and menu-bar gauge never disagree with the rings. Falls
    /// back to the backend's inferred per-instance quota when no real data is available.
    func displayPercent(for source: SourceStatus) -> Double {
        if source.id == "claude-code",
           let anth = quotaState.anthropicState,
           anth.source == .oauthAPI,
           let real = anth.fiveHourPct {
            return real
        }
        return source.percentUsed
    }

    func formatResetTime(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "resetting..." }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM"
            return "resets \(formatter.string(from: date))"
        }
        if hours > 0 {
            return "resets in \(hours)h \(minutes)m"
        }
        return "resets in \(minutes)m"
    }
}
