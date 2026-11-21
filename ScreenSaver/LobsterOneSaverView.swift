import ScreenSaver
import CoreText
import os

/// Shows the usage figures the menu bar app last wrote to `screensaver.json`, beside a small
/// scene of Garry sorting shells at a pace set by the current token rate.
///
/// It runs inside Apple's sandboxed `legacyScreenSaver` host, which shapes three decisions
/// (the first two observed on macOS 26.3, 15 Nov 2026):
///
///   * Data comes from a file only. The host can read anywhere under the real home
///     directory, so no credentials and no network code are needed here.
///   * The host never calls `stopAnimation` on a full-screen instance, keeps old instances
///     alive across runs, and after we exit it relaunches itself within 200 ms and starts a
///     fresh instance nobody can see. So there is always a copy of this view running off
///     screen. The figures cost almost nothing at any time: one file stat every few seconds
///     and one redraw a minute. Exiting on `willstop` throws away the piled-up instances.
///   * The den scene costs a little CPU (2 to 3% of a core across two displays), so it should
///     not run on the hidden copy. Nothing the host offers says reliably whether a copy is
///     displayed: the window always claims to be visible, `didstart` is not always sent, and
///     Apple's ScreenSaverEngine app can go away while the saver is still on screen (a locked
///     screen). So the rule leans towards animating: a copy animates unless there is a
///     positive reason to think it is hidden. A frozen lobster on screen is a bug; a moving
///     one nobody sees is a small waste. See "Which instance is on screen" below.
@objc(LobsterOneSaverView)
final class LobsterOneSaverView: ScreenSaverView {
    private static let logger = Logger(subsystem: "ai.lobsterone.screensaver", category: "lifecycle")
    private static let willStop = Notification.Name("com.apple.screensaver.willstop")
    private static let didStart = Notification.Name("com.apple.screensaver.didstart")
    private static let didStop = Notification.Name("com.apple.screensaver.didstop")
    /// The app polls every 5 to 15 minutes. Past this, say so on screen.
    private static let staleAfter: TimeInterval = 45 * 60
    /// Apple's host appears to update the screen only when the saver produces a frame, so
    /// Core Animation alone does not make motion smooth there: the saver has to run at the
    /// display's rate while something moves. Static designs drop to two frames a second.
    private static let framesPerSecond = 60
    private static let staticFramesPerSecond = 2
    private static let reloadEverySeconds = 5

    private let fileURL = ScreensaverSnapshot.fileURL(home: ScreensaverSnapshot.realHome)
    private let den = DenView(frame: .zero)
    /// The design named in the snapshot. Anything but the den is a full-screen view.
    private var style: ScreensaverStyle = .den
    private var altView: (NSView & SaverStyleView)?
    private var snapshot: ScreensaverSnapshot?
    private var fileModified: Date?
    private var ticks = 0
    private var seconds = 0
    private var lastSecond = Date()
    private var loggedPresentation = false
    private var laidOutMinute = -1
    private var layout = Layout(unit: 1, statsLeft: 0, statsTop: 0, den: .zero)
    private var live = false
    private var created = Date()
    private var loggedCost = false

    // MARK: - Lifecycle

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        SaverFonts.register()
        addSubview(den)
        reloadIfChanged()
        relayout()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hostWillStop), name: Self.willStop, object: nil)
        Self.logger.notice("init preview=\(isPreview, privacy: .public) size=\(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public)")

        created = Date()
        Self.instances.add(self)
        Self.watchHost()
        Self.refreshLiveness()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fitToHost()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitToHost()
    }

    /// With two displays the host makes one view per display, each sized for its display,
    /// but does not always put it in that display's window (macOS 26.3, 21 Nov 2026: the
    /// creation order flips between runs). A 1440x2560 view in a 3440x1440 window covered
    /// only the left of the screen. So the view takes the size of whatever it lands in.
    /// Left alone in the System Settings picker, which draws a full-size copy scaled down.
    private func fitToHost() {
        guard !isPreview, !Self.settingsPicker, let container = superview else { return }
        autoresizingMask = [.width, .height]
        let target = container.bounds
        guard target.width > 0, target.height > 0, frame != target else { return }
        Self.logger.notice("resized \(Int(self.frame.width), privacy: .public)x\(Int(self.frame.height), privacy: .public) to fit its window: \(Int(target.width), privacy: .public)x\(Int(target.height), privacy: .public)")
        frame = target
    }

    override func animateOneFrame() {
        ticks += 1
        if Date().timeIntervalSince(lastSecond) >= 1 {
            lastSecond = Date()
            everySecond()
        }

        guard live, !Self.screensAsleep else { return }
        // Logged once on screen: when going live the view often has no window yet.
        if !loggedPresentation, window != nil {
            loggedPresentation = true
            fitToHost()
            logPresentation()
        }
        if let altView {
            altView.tick()
            return
        }
        guard den.scene.isAnimating else { return }
        den.scene.step(animationTimeInterval)
        den.render()
    }

    private func everySecond() {
        seconds += 1
        // The live rate is a sliding minute, so it moves every second while events are recent.
        if let last = Self.lastLiveEvent, Date().timeIntervalSince(last) < Self.liveWindow + 61 {
            applySnapshotToDen()
        }
        if seconds % Self.reloadEverySeconds == 0 { reloadIfChanged() }
        if Self.settingsPicker != compactLaidOut {
            Self.logger.notice("layout: \(Self.settingsPicker ? "compact (System Settings picker)" : "full", privacy: .public)")
            relayout()
            Self.refreshLiveness()
        }
        if live, !loggedCost, let mark = Self.cpuAtSessionLog, Date().timeIntervalSince(mark.at) >= 10 {
            loggedCost = true
            Self.logger.notice("design \(self.style.rawValue, privacy: .public)")
            if let mark = Self.cpuAtSessionLog {
                let wall = Date().timeIntervalSince(mark.at), used = Self.processCPU() - mark.cpu
                Self.logger.notice("process used \(String(format: "%.2f", used), privacy: .public)s CPU in \(String(format: "%.1f", wall), privacy: .public)s showing (\(String(format: "%.1f", used / wall * 100), privacy: .public)%)")
            }
            guard den.drawCount > 0 else { return }
            let each = den.drawSeconds / Double(den.drawCount) * 1000
            Self.logger.notice("den frame \(String(format: "%.2f", each), privacy: .public) ms over \(self.den.drawCount, privacy: .public) frames at \(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public)")
        }
        // Relative times ("updated 3m ago"), staleness and the drift only change with the minute.
        if Self.minute(of: Date()) != laidOutMinute {
            applySnapshotToDen()
            relayout()
        }
    }

    // MARK: - Which instance is on screen

    private static var instances = NSHashTable<LobsterOneSaverView>.weakObjects()
    private static var screensAsleep = false
    private static var watching = false
    /// When the current showing began. Nil while we believe nothing is displayed.
    private static var showingSince: Date?
    private static var engineWasRunning = false
    private static let processStarted = Date()
    private static var cpuAtSessionLog: (cpu: Double, at: Date)?
    /// Model responses announced by the app, newest last, kept for a minute.
    private static var liveEvents: [(at: Date, tokens: Int)] = []
    private static var lastLiveEvent: Date? { liveEvents.last?.at ?? lastPrunedLiveEvent }
    private static var lastPrunedLiveEvent: Date?
    private static var liveEventsThisShowing = 0
    /// How long after the last live event the den keeps trusting live events over the polled
    /// rate. Longer than any gap between responses in a working session.
    private static let liveWindow: TimeInterval = 10 * 60

    /// Written when we exit on dismissal. The host relaunches us within a second and starts a
    /// copy nobody can see; this is how that copy knows to stay still.
    private static let stopMarker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lobsterone-saver-stopped")
    private static let bornHidden: Bool = {
        let stopped = (try? FileManager.default.attributesOfItem(atPath: stopMarker.path))?[.modificationDate] as? Date
        return stopped.map { Date().timeIntervalSince($0) < 5 } ?? false
    }()

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static var engineRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").contains { !$0.isTerminated }
    }

    private static func watchHost() {
        guard !watching else { return }
        watching = true
        engineWasRunning = engineRunning
        if !bornHidden || engineWasRunning { begin("process start") } else { logger.notice("born hidden, staying still") }

        let center = DistributedNotificationCenter.default()
        for name in [didStart, Notification.Name("com.apple.screenIsLocked")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in begin(name.rawValue) }
        }
        // One per model response, from the app's live log watcher (LiveActivityWatcher.swift).
        center.addObserver(forName: Notification.Name("ai.lobsterone.activity"), object: nil, queue: .main) { note in
            let tokens = (note.userInfo?["tokens"] as? Int) ?? 0
            liveEvents.append((Date(), tokens))
            liveEventsThisShowing += 1
            if liveEventsThisShowing == 1, showingSince != nil {
                logger.notice("first live event this showing: \(tokens, privacy: .public) tokens")
            }
            let source = (note.userInfo?["source"] as? String) ?? "claude"
            let kind = (note.userInfo?["kind"] as? String) ?? "answer"
            for view in instances.allObjects where view.live {
                if let alt = view.altView {
                    alt.liveEvent(tokens: tokens, source: source, kind: kind)
                } else {
                    view.den.scene.drop()
                }
                view.applySnapshotToDen()
            }
        }
        for name in [didStop, willStop, Notification.Name("com.apple.screenIsUnlocked")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in end(name.rawValue) }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in screensAsleep = true }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in screensAsleep = false }

        // The engine starting is only visible by looking. Its going away proves nothing.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let running = engineRunning
            if running, !engineWasRunning { begin("engine started") }
            engineWasRunning = running
            checkForInput()
        }
    }

    private static func begin(_ reason: String) {
        if showingSince == nil {
            showingSince = Date()
            liveEventsThisShowing = 0
            cpuAtSessionLog = (processCPU(), Date())
            logger.notice("showing (\(reason, privacy: .public))")
        }
        refreshLiveness()
    }

    private static func end(_ reason: String) {
        if showingSince != nil {
            logger.notice("not showing (\(reason, privacy: .public)), \(liveEventsThisShowing, privacy: .public) live events")
        }
        liveEventsThisShowing = 0
        showingSince = nil
        refreshLiveness()
    }

    /// When input began arriving without a break, if it has.
    private static var activeSince: Date?
    /// Someone at the keyboard keeps producing input; a saver still up does not.
    private static let sustainedInput: TimeInterval = 8

    /// A screensaver ends on input (or shows a login panel over itself). If none of the stop
    /// signals arrived, this still settles a copy that is animating unseen. A single event is
    /// not enough: a nudged mouse or a touch of the trackpad registers as input without
    /// dismissing the saver (seen on macOS 26.3), which used to leave the rain to run dry on
    /// screen. Input has to keep coming for a few seconds, as it does once someone is back.
    private static func checkForInput() {
        guard let since = showingSince, instances.allObjects.contains(where: { !$0.isPreview }) else {
            activeSince = nil
            return
        }
        let showing = Date().timeIntervalSince(since)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard showing > 20, idle < 3 else {
            activeSince = nil
            return
        }
        let start = activeSince ?? Date()
        activeSince = start
        if Date().timeIntervalSince(start) >= sustainedInput {
            activeSince = nil
            end("input for \(Int(sustainedInput))s")
        }
    }

    /// Within a showing, the copies the host created for it are the displayed ones, newest
    /// first and never more than one per display; if it created none, it is showing the ones
    /// it already had.
    private static func refreshLiveness() {
        let views = instances.allObjects
        let fullScreen = views.filter { !$0.isPreview }
        let displays = max(NSScreen.screens.count, 1)
        func newest(_ views: [LobsterOneSaverView]) -> [LobsterOneSaverView] {
            Array(views.sorted { $0.created > $1.created }.prefix(displays))
        }
        let fresh = newest(showingSince.map { start in fullScreen.filter { $0.created >= start.addingTimeInterval(-1) } } ?? [])
        let shown = fresh.isEmpty ? newest(fullScreen) : fresh
        for view in views {
            if view.isPreview {
                // The thumbnail in System Settings, or a test harness.
                view.setLive(true, "preview")
            } else if showingSince == nil, settingsPicker, newest(fullScreen).contains(view) {
                // The picker's thumbnail is a full-size copy; it is on screen while System
                // Settings is open, and costs nothing once it quits.
                view.setLive(true, "System Settings picker")
            } else if showingSince == nil {
                view.setLive(false, "not showing")
            } else {
                view.setLive(shown.contains(view), shown.contains(view) ? "showing" : "spare copy")
            }
        }
    }

    /// The host calls this on copies it is about to display, including ones it made earlier.
    override func startAnimation() {
        super.startAnimation()
        guard !isPreview else { return }
        // The unseen copy made right after a dismissal gets this call too.
        if Self.bornHidden, Date().timeIntervalSince(Self.processStarted) < 5 { return }
        Self.begin("startAnimation")
    }

    private func setLive(_ value: Bool, _ reason: String) {
        guard value != live else { return }
        live = value
        applyFrameRate()
        Self.logger.notice("live=\(value, privacy: .public) (\(reason, privacy: .public))")
        loggedPresentation = false
    }

    /// A hidden instance only needs to notice a new snapshot; once a second is plenty.
    private func applyFrameRate() {
        let moving = altView == nil || altView is MatrixStyleView
        animationTimeInterval = !live ? 1 : 1 / Double(moving ? Self.framesPerSecond : Self.staticFramesPerSecond)
    }

    /// How the host shows us, to diagnose motion problems on other macOS versions.
    private func logPresentation() {
        let window = self.window
        let fps = window?.screen?.maximumFramesPerSecond ?? 0
        let screen = window?.screen?.frame.size ?? .zero
        Self.logger.notice("presented in \(window.map { String(describing: type(of: $0)) } ?? "no window", privacy: .public) at \(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public) on a \(Int(screen.width), privacy: .public)x\(Int(screen.height), privacy: .public) screen, screen max \(fps, privacy: .public) fps, layer-backed \(self.layer != nil, privacy: .public), interval \(String(format: "%.3f", self.animationTimeInterval), privacy: .public)s")
    }

    @objc private func hostWillStop() {
        // The System Settings preview shares this notification; leave that process alone.
        guard !isPreview else { return }
        try? Data().write(to: Self.stopMarker)
        Self.logger.notice("willstop, exiting to release stale instances")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    // MARK: - Data

    private func reloadIfChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard modified != fileModified else { return }
        fileModified = modified

        if modified == nil {
            snapshot = nil
        } else if let data = try? Data(contentsOf: fileURL), let decoded = ScreensaverSnapshot.decode(data) {
            snapshot = decoded
        } else {
            // Unreadable, or written by a newer app than this screensaver understands.
            Self.logger.error("snapshot at \(self.fileURL.path, privacy: .public) could not be read")
            snapshot = nil
        }
        applyStyle()
        applySnapshotToDen()
        needsDisplay = true
    }

    private func applyStyle() {
        let wanted = snapshot?.style ?? .standard
        guard wanted != style else { return }
        style = wanted
        altView?.removeFromSuperview()
        switch wanted {
        case .den: altView = nil
        case .dashboard: altView = DashboardStyleView(frame: bounds)
        case .leaderboard: altView = LeaderboardStyleView(frame: bounds)
        case .matrix: altView = MatrixStyleView(frame: bounds)
        }
        if let altView { addSubview(altView) }
        den.isHidden = altView != nil
        applyFrameRate()
        Self.logger.notice("design: \(wanted.rawValue, privacy: .public)")
        relayout()
    }

    /// The rate is only trusted while the snapshot is fresh; an old figure would keep Garry
    /// busy for hours after the work stopped.
    private func applySnapshotToDen() {
        let now = Date()
        var rate = 0.0
        let live: Bool
        if let last = Self.lastLiveEvent, now.timeIntervalSince(last) < Self.liveWindow {
            // Live: tokens in responses over the last minute.
            live = true
            if let newest = Self.liveEvents.last?.at { Self.lastPrunedLiveEvent = newest }
            Self.liveEvents.removeAll { now.timeIntervalSince($0.at) > 60 }
            rate = Double(Self.liveEvents.reduce(0) { $0 + $1.tokens })
            // A response with no counted tokens is still activity.
            if rate == 0, !Self.liveEvents.isEmpty { rate = 1 }
        } else {
            live = false
            if let snapshot, !snapshot.isOffline, now.timeIntervalSince(snapshot.updatedAt) <= Self.staleAfter {
                rate = max(snapshot.tokensPerMinute, 0)
            }
        }
        den.scene.liveMode = live
        den.scene.tokensPerMinute = rate
        if snapshot == nil, !live {
            den.caption = ""
        } else if rate > 0 {
            den.caption = "\(SevenDayBurn.formatTokens(Int(rate))) TOK/MIN\(live ? "  ·  LIVE" : "")"
        } else {
            den.caption = "QUIET RIGHT NOW"
        }
        altView?.update(snapshot: snapshot, rate: rate, live: live)
        den.render()
    }

    private static func minute(of date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 60)
    }

    // MARK: - Layout

    /// Everything is measured in units; `unit` converts to points for this screen.
    private struct Layout {
        var unit: CGFloat
        var statsLeft: CGFloat
        var statsTop: CGFloat
        var den: NSRect
        /// The thumbnail-sized preview in System Settings: headline and den only.
        var compact = false
    }

    private static let statsSize = CGSize(width: 760, height: 650)
    /// Below this width the full layout's text is too small to read.
    private static let compactBelow: CGFloat = 600
    /// System Settings' picker shows a copy drawn at full display size and scaled into a small
    /// box, and that copy is not flagged as a preview (macOS 26.3: the flagged one gets a zero
    /// size). What sets the picker apart is that Apple's ScreenSaverEngine app is not running
    /// while System Settings is. Re-checked every second, so a real screensaver starting
    /// switches straight to the full layout.
    private static var settingsPicker: Bool {
        guard Bundle.main.bundleIdentifier == "com.apple.ScreenSaver.Engine.legacyScreenSaver" else { return false }
        return !engineRunning
            && NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").contains { !$0.isTerminated }
    }
    private var compactLaidOut = false

    /// Wide screens put the den to the right of the figures; tall or squarish ones put it
    /// underneath. Either way the unit shrinks until everything fits.
    private func relayout() {
        let width = bounds.width, height = bounds.height
        guard width > 0, height > 0 else { return }
        laidOutMinute = Self.minute(of: Date())
        compactLaidOut = Self.settingsPicker

        if let altView {
            // Shift the whole design a little each minute so nothing sits on the same pixels.
            let unit = min(height / 900, width / 1500)
            let drift = CGPoint(x: sin(Double(laidOutMinute) / 7) * 24 * unit, y: cos(Double(laidOutMinute) / 11) * 18 * unit)
            altView.frame = bounds.offsetBy(dx: drift.x, dy: drift.y).integral
            altView.needsDisplay = true
            needsDisplay = true
            return
        }

        let stats = Self.statsSize
        let denAspect = DenScene.size.height / DenScene.size.width
        var result: Layout

        compactLaidOut = Self.settingsPicker
        if width < Self.compactBelow || compactLaidOut {
            // Headline across the top, the den as large as fits underneath. No drift: this is
            // only ever a preview.
            let margin = width * 0.06
            let denAspect = DenScene.size.height / DenScene.size.width
            let denWidth = min(width - 2 * margin, height * 0.52 / denAspect)
            let denHeight = denWidth * denAspect
            layout = Layout(unit: height / 900, statsLeft: margin, statsTop: height - margin * 0.8,
                            den: NSRect(x: (width - denWidth) / 2, y: 0, width: denWidth, height: denHeight).integral,
                            compact: true)
            den.unit = layout.unit
            den.showsCaption = false
            den.frame = layout.den
            den.render()
            needsDisplay = true
            return
        }
        den.showsCaption = true

        if width / height >= 1.45 {
            let gap: CGFloat = 70, margin: CGFloat = 110, minimumDen: CGFloat = 620
            let unit = min(height / 900, width * 0.88 / (stats.width + gap + minimumDen))
            let regionLeft = (margin + stats.width + gap) * unit
            let regionWidth = width - margin * unit - regionLeft
            let denWidth = min(regionWidth, DenScene.size.width * unit, height * 0.6 / denAspect)
            result = Layout(
                unit: unit,
                statsLeft: margin * unit,
                statsTop: height / 2 + stats.height / 2 * unit,
                den: NSRect(x: regionLeft + (regionWidth - denWidth) / 2,
                            y: height / 2 - denWidth * denAspect / 2,
                            width: denWidth, height: denWidth * denAspect))
        } else {
            let gap: CGFloat = 60
            let denUnits = CGSize(width: stats.width, height: stats.width * denAspect)
            let totalHeight = stats.height + gap + denUnits.height
            let unit = min(width * 0.84 / stats.width, height / (totalHeight + 180))
            let left = (width - stats.width * unit) / 2
            let top = height / 2 + totalHeight / 2 * unit
            result = Layout(
                unit: unit,
                statsLeft: left,
                statsTop: top,
                den: NSRect(x: left, y: top - totalHeight * unit,
                            width: denUnits.width * unit, height: denUnits.height * unit))
        }

        // Nudge everything once a minute so nothing sits on the same pixels for hours.
        let drift = CGPoint(x: sin(Double(laidOutMinute) / 7) * 30 * result.unit,
                            y: cos(Double(laidOutMinute) / 11) * 24 * result.unit)
        result.statsLeft += drift.x
        result.statsTop += drift.y
        result.den = result.den.offsetBy(dx: drift.x, dy: drift.y).integral

        layout = result
        den.unit = result.unit
        den.frame = result.den
        den.render()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        let now = Date()

        SaverPalette.background.setFill()
        bounds.fill()
        guard altView == nil else { return }

        if layout.compact {
            drawCompact()
            return
        }

        let scale = layout.unit
        var pen = Pen(x: layout.statsLeft, y: layout.statsTop, scale: scale)

        pen.text("LOBSTERONE", SaverFonts.mono(13 * scale, .medium), SaverPalette.brand, kern: 2.4 * scale)
        pen.space(34)

        guard let snapshot else {
            pen.text("Nothing to show yet", SaverFonts.sans(72 * scale, .light), SaverPalette.secondary)
            pen.space(22)
            pen.text("Open LobsterOne in the menu bar", SaverFonts.mono(15 * scale), SaverPalette.tertiary)
            pen.space(6)
            pen.text("and your usage appears here.", SaverFonts.mono(15 * scale), SaverPalette.tertiary)
            return
        }

        let age = now.timeIntervalSince(snapshot.updatedAt)
        let isStale = age > Self.staleAfter

        // The headline shrinks to fit rather than run off a narrow screen.
        let figure = snapshot.tokens.formatted(.number.grouping(.automatic))
        var figureFont = SaverFonts.sans(168 * scale, .light)
        let figureWidth = NSAttributedString(string: figure, attributes: [.font: figureFont]).size().width
        let available = Self.statsSize.width * scale
        if figureWidth > available {
            figureFont = SaverFonts.sans(168 * scale * available / figureWidth, .light)
        }
        pen.text(figure, figureFont, isStale ? SaverPalette.secondary : SaverPalette.text)
        pen.space(4)
        let caption = snapshot.plan.isEmpty ? "TOKENS" : "TOKENS  ·  \(snapshot.plan.uppercased())"
        pen.text(caption, SaverFonts.mono(13 * scale), SaverPalette.secondary, kern: 1.6 * scale)
        pen.space(64)

        drawSession(snapshot, now: now, pen: &pen)
        if snapshot.sevenDay.contains(where: { $0.tokens > 0 }) {
            pen.space(58)
            drawSevenDay(snapshot.sevenDay, pen: &pen)
        }

        pen.space(64)
        pen.text(Self.footer(snapshot, age: age, isStale: isStale), SaverFonts.mono(12 * scale), SaverPalette.tertiary)
    }

    /// Today's tokens in large type over a small brand line, sized from the preview's height.
    private func drawCompact() {
        let height = bounds.height
        var pen = Pen(x: layout.statsLeft, y: layout.statsTop, scale: 1)
        pen.text("LOBSTERONE", SaverFonts.mono(max(6, height * 0.055), .medium), SaverPalette.brand, kern: height * 0.008)
        pen.y -= height * 0.015
        guard let snapshot else { return }
        let stale = Date().timeIntervalSince(snapshot.updatedAt) > Self.staleAfter
        let figure = snapshot.tokens.formatted(.number.grouping(.automatic))
        var font = SaverFonts.sans(height * 0.2, .light)
        let fits = bounds.width - 2 * layout.statsLeft
        let wide = NSAttributedString(string: figure, attributes: [.font: font]).size().width
        if wide > fits { font = SaverFonts.sans(height * 0.2 * fits / wide, .light) }
        pen.text(figure, font, stale ? SaverPalette.secondary : SaverPalette.text)
    }

    private func drawSession(_ snapshot: ScreensaverSnapshot, now: Date, pen: inout Pen) {
        let scale = pen.scale
        let percent = min(max(snapshot.percentUsed, 0), 100)

        pen.text("SESSION", SaverFonts.mono(12 * scale), SaverPalette.tertiary, kern: 1.6 * scale)
        pen.space(14)

        let width = 460 * scale, height = 6 * scale
        let track = NSRect(x: pen.x, y: pen.y - height, width: width, height: height)
        SaverPalette.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
        if percent > 0 {
            var fill = track
            fill.size.width = max(height, width * percent / 100)
            (percent >= 80 ? SaverPalette.critical : SaverPalette.brand).setFill()
            NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
        }

        let figure = "\(snapshot.isRealQuota ? "" : "~")\(Int(percent.rounded()))%"
        var side = Pen(x: pen.x + width + 26 * scale, y: pen.y + 13 * scale, scale: scale)
        let figureWidth = side.text(figure, SaverFonts.sans(28 * scale, .regular), SaverPalette.text, advance: false)
        if let resets = Self.resetText(snapshot.resetsAt, now: now) {
            side.x += figureWidth + 16 * scale
            side.y -= 12 * scale
            side.text(resets, SaverFonts.mono(12 * scale), SaverPalette.secondary, advance: false)
        }
        pen.space(6)
    }

    private func drawSevenDay(_ days: [ScreensaverSnapshot.Day], pen: inout Pen) {
        let scale = pen.scale
        let total = days.reduce(0) { $0 + max(0, $1.tokens) }

        let labelWidth = pen.text("LAST 7 DAYS", SaverFonts.mono(12 * scale), SaverPalette.tertiary,
                                  kern: 1.6 * scale, advance: false)
        var side = Pen(x: pen.x + labelWidth + 18 * scale, y: pen.y, scale: scale)
        side.text("\(SevenDayBurn.formatTokens(total)) tok", SaverFonts.mono(12 * scale), SaverPalette.secondary, advance: false)
        pen.space(34)

        let barWidth = 46 * scale, gap = 14 * scale, maxHeight = 92 * scale
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        let baseline = pen.y - maxHeight

        for (index, day) in days.enumerated() {
            let x = pen.x + CGFloat(index) * (barWidth + gap)
            let height = max(3 * scale, maxHeight * CGFloat(max(0, day.tokens)) / CGFloat(peak))
            (index == days.count - 1 ? SaverPalette.brand : SaverPalette.bar).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseline, width: barWidth, height: height),
                         xRadius: 3 * scale, yRadius: 3 * scale).fill()

            let initial = SevenDayBurn.Day(date: day.date, tokens: day.tokens, costUsd: 0).weekdayInitial
            let label = NSAttributedString(string: initial, attributes: [
                .font: SaverFonts.mono(11 * scale), .foregroundColor: SaverPalette.tertiary,
            ])
            label.draw(at: NSPoint(x: x + (barWidth - label.size().width) / 2,
                                   y: baseline - 12 * scale - label.size().height))
        }
        pen.y = baseline - 12 * scale - 14 * scale
    }

    private static func resetText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        // A reset time in the past means the snapshot predates the reset; say nothing.
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(max(minutes, 1))m"
    }

    private static func footer(_ snapshot: ScreensaverSnapshot, age: TimeInterval, isStale: Bool) -> String {
        let updated = "updated \(ago(age))"
        if isStale { return "\(updated)  ·  is LobsterOne running?" }
        if snapshot.isOffline { return "offline  ·  \(updated)" }
        return updated
    }

    private static func ago(_ age: TimeInterval) -> String {
        let minutes = Int(max(age, 0) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }
}

/// A text cursor that moves down the screen. `y` is the top of the next line.
private struct Pen {
    var x: CGFloat
    var y: CGFloat
    let scale: CGFloat

    /// Draws one line and returns its width. Moves down by the line's height unless told not to.
    @discardableResult
    mutating func text(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0, advance: Bool = true) -> CGFloat {
        let line = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let size = line.size()
        line.draw(at: NSPoint(x: x, y: y - size.height))
        if advance { y -= size.height }
        return size.width
    }

    mutating func space(_ points: CGFloat) {
        y -= points * scale
    }
}

/// The menu bar popover's dark palette.
enum SaverPalette {
    static let background = NSColor(srgbRed: 0x1F / 255, green: 0x1A / 255, blue: 0x17 / 255, alpha: 1)
    static let track = NSColor(srgbRed: 0x2E / 255, green: 0x27 / 255, blue: 0x23 / 255, alpha: 1)
    static let bar = NSColor(srgbRed: 0x4A / 255, green: 0x40 / 255, blue: 0x39 / 255, alpha: 1)
    static let text = NSColor(srgbRed: 0xED / 255, green: 0xE8 / 255, blue: 0xE1 / 255, alpha: 1)
    static let secondary = NSColor(srgbRed: 0xA8 / 255, green: 0xA2 / 255, blue: 0x9E / 255, alpha: 1)
    static let tertiary = NSColor(srgbRed: 0x78 / 255, green: 0x71 / 255, blue: 0x6C / 255, alpha: 1)
    static let brand = NSColor(srgbRed: 0xC8 / 255, green: 0x4C / 255, blue: 0x22 / 255, alpha: 1)
    static let critical = NSColor(srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)
}

/// The app's typefaces, copied into this bundle by `build.sh`. Falls back to system fonts.
enum SaverFonts {
    static func register() {
        _ = registered
    }

    private static let registered: Void = {
        let bundle = Bundle(for: LobsterOneSaverView.self)
        for name in ["BricolageGrotesque", "JetBrainsMono"] {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        named("Bricolage Grotesque", size, weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        named("JetBrains Mono", size, weight) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func named(_ family: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { return nil }
        return font
    }
}
