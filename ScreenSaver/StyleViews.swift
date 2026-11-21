import AppKit
import QuartzCore

/// A full-screen design other than the den. The saver view owns the data and timing and
/// forwards it here; each design only draws.
protocol SaverStyleView: NSView {
    /// New figures, or the live rate moving. Cheap to call every second.
    func update(snapshot: ScreensaverSnapshot?, rate: Double, live: Bool)
    /// One model response, as announced by the app. `kind` is "answer", "tool" or "edit".
    func liveEvent(tokens: Int, source: String, kind: String)
    /// 15 times a second while on screen. Designs that do not animate ignore it.
    func tick()
}

extension SaverStyleView {
    func tick() {}
}

/// Shared drawing helpers for the text-based designs.
private enum Ink {
    static func text(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    }

    /// Draws with its top-left at `point` and returns its size.
    @discardableResult
    static func draw(_ string: NSAttributedString, topLeft point: NSPoint) -> NSSize {
        let size = string.size()
        string.draw(at: NSPoint(x: point.x, y: point.y - size.height))
        return size
    }

    static func label(_ string: String, _ unit: CGFloat, _ color: NSColor = SaverPalette.tertiary) -> NSAttributedString {
        text(string.uppercased(), SaverFonts.mono(12 * unit), color, kern: 1.6 * unit)
    }

    static func card(_ rect: NSRect, _ unit: CGFloat) {
        NSColor(srgbRed: 0x26 / 255, green: 0x20 / 255, blue: 0x19 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16 * unit, yRadius: 16 * unit).fill()
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func rate(_ rate: Double, live: Bool) -> String {
        guard rate > 0 else { return "quiet right now" }
        return "\(SevenDayBurn.formatTokens(Int(rate))) tok/min\(live ? " · live" : "")"
    }
}

// MARK: - Dashboard

/// The menu bar popover as panels: today's tokens, the session, a split by tool, the week and
/// a feed of responses as they land.
final class DashboardStyleView: NSView, SaverStyleView {
    private var snapshot: ScreensaverSnapshot?
    private var rate = 0.0
    private var live = false
    private var feed: [(at: Date, tokens: Int, source: String)] = []

    override var isOpaque: Bool { true }

    func update(snapshot: ScreensaverSnapshot?, rate: Double, live: Bool) {
        guard snapshot != self.snapshot || rate != self.rate || live != self.live else { return }
        self.snapshot = snapshot
        self.rate = rate
        self.live = live
        needsDisplay = true
    }

    func liveEvent(tokens: Int, source: String, kind: String) {
        feed.insert((Date(), tokens, source), at: 0)
        feed = Array(feed.prefix(7))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SaverPalette.background.setFill()
        bounds.fill()
        let u = min(bounds.height / 900, bounds.width / 1500)
        let margin = 90 * u, gap = 24 * u
        let area = bounds.insetBy(dx: (bounds.width - min(bounds.width - 2 * margin, 1500 * u)) / 2, dy: margin)
        Ink.draw(Ink.label("LobsterOne", u, SaverPalette.brand), topLeft: NSPoint(x: area.minX, y: area.maxY))

        guard let snapshot else {
            Ink.draw(Ink.text("Open LobsterOne in the menu bar and your usage appears here.", SaverFonts.mono(15 * u), SaverPalette.tertiary),
                     topLeft: NSPoint(x: area.minX, y: area.maxY - 40 * u))
            return
        }

        let grid = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - 50 * u)
        let columnWidth = (grid.width - 2 * gap) / 3
        let topHeight = grid.height * 0.42
        let top = NSRect(x: grid.minX, y: grid.maxY - topHeight, width: columnWidth, height: topHeight)
        let pad = 26 * u

        // Tokens today.
        Ink.card(top, u)
        var y = top.maxY - pad
        y -= Ink.draw(Ink.label("Tokens today", u), topLeft: NSPoint(x: top.minX + pad, y: y)).height + 10 * u
        let figure = Ink.text(Ink.tokens(snapshot.tokens), SaverFonts.sans(min(96 * u, columnWidth * 0.17), .light), SaverPalette.text)
        y -= Ink.draw(figure, topLeft: NSPoint(x: top.minX + pad, y: y)).height + 6 * u
        let plan = snapshot.plan.isEmpty ? "" : "\(snapshot.plan.uppercased())  ·  "
        Ink.draw(Ink.text(plan + Ink.rate(rate, live: live), SaverFonts.mono(13 * u), SaverPalette.secondary),
                 topLeft: NSPoint(x: top.minX + pad, y: y))

        // Session ring.
        let session = top.offsetBy(dx: columnWidth + gap, dy: 0)
        Ink.card(session, u)
        let percent = min(max(snapshot.percentUsed, 0), 100)
        let radius = min(session.height * 0.3, session.width * 0.2)
        let centre = NSPoint(x: session.minX + pad + radius + 8 * u, y: session.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 14 * u
        SaverPalette.track.setStroke()
        track.stroke()
        if percent > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius, startAngle: 90, endAngle: 90 - 360 * percent / 100, clockwise: true)
            arc.lineWidth = 14 * u
            arc.lineCapStyle = .round
            (percent >= 80 ? SaverPalette.critical : SaverPalette.brand).setStroke()
            arc.stroke()
        }
        let textX = centre.x + radius + 30 * u
        var sy = session.midY + 50 * u
        sy -= Ink.draw(Ink.label("Session", u), topLeft: NSPoint(x: textX, y: sy)).height + 6 * u
        sy -= Ink.draw(Ink.text("\(snapshot.isRealQuota ? "" : "~")\(Int(percent.rounded()))%", SaverFonts.sans(52 * u), SaverPalette.text),
                       topLeft: NSPoint(x: textX, y: sy)).height + 4 * u
        if let resets = snapshot.resetsAt, resets > Date() {
            let minutes = Int(resets.timeIntervalSinceNow / 60)
            let text = minutes >= 60 ? "resets in \(minutes / 60)h \(minutes % 60)m" : "resets in \(max(minutes, 1))m"
            Ink.draw(Ink.text(text, SaverFonts.mono(13 * u), SaverPalette.secondary), topLeft: NSPoint(x: textX, y: sy))
        }

        // By tool.
        let tools = session.offsetBy(dx: columnWidth + gap, dy: 0)
        Ink.card(tools, u)
        var ty = tools.maxY - pad
        ty -= Ink.draw(Ink.label("By tool today", u), topLeft: NSPoint(x: tools.minX + pad, y: ty)).height + 18 * u
        let sources = snapshot.sources ?? []
        let total = max(sources.reduce(0) { $0 + $1.tokens }, 1)
        if sources.isEmpty {
            Ink.draw(Ink.text("No tool activity yet today", SaverFonts.mono(13 * u), SaverPalette.tertiary), topLeft: NSPoint(x: tools.minX + pad, y: ty))
        }
        for (index, source) in sources.prefix(4).enumerated() {
            let share = Double(source.tokens) / Double(total)
            let name = Ink.text(source.name, SaverFonts.sans(17 * u), SaverPalette.text)
            Ink.draw(name, topLeft: NSPoint(x: tools.minX + pad, y: ty))
            let pct = Ink.text("\(Int((share * 100).rounded()))%", SaverFonts.mono(14 * u), SaverPalette.secondary)
            Ink.draw(pct, topLeft: NSPoint(x: tools.maxX - pad - pct.size().width, y: ty))
            ty -= name.size().height + 8 * u
            let bar = NSRect(x: tools.minX + pad, y: ty - 6 * u, width: tools.width - 2 * pad, height: 6 * u)
            SaverPalette.track.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3 * u, yRadius: 3 * u).fill()
            (index == 0 ? SaverPalette.brand : SaverPalette.bar).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * share), height: bar.height),
                         xRadius: 3 * u, yRadius: 3 * u).fill()
            ty -= 26 * u
        }

        // The week.
        let bottomHeight = grid.height - topHeight - gap
        let week = NSRect(x: grid.minX, y: grid.minY, width: columnWidth * 2 + gap, height: bottomHeight)
        Ink.card(week, u)
        let weekTotal = snapshot.sevenDay.reduce(0) { $0 + max(0, $1.tokens) }
        Ink.draw(Ink.label("Last 7 days  ·  \(SevenDayBurn.formatTokens(weekTotal)) tok", u), topLeft: NSPoint(x: week.minX + pad, y: week.maxY - pad))
        let days = snapshot.sevenDay
        if !days.isEmpty {
            let chart = NSRect(x: week.minX + pad, y: week.minY + pad + 24 * u, width: week.width - 2 * pad, height: week.height - 2 * pad - 70 * u)
            let barGap = 18 * u
            let barWidth = (chart.width - barGap * CGFloat(days.count - 1)) / CGFloat(days.count)
            let peak = max(days.map(\.tokens).max() ?? 1, 1)
            for (index, day) in days.enumerated() {
                let x = chart.minX + CGFloat(index) * (barWidth + barGap)
                let height = max(4 * u, chart.height * CGFloat(max(0, day.tokens)) / CGFloat(peak))
                (index == days.count - 1 ? SaverPalette.brand : SaverPalette.bar).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: chart.minY, width: barWidth, height: height), xRadius: 5 * u, yRadius: 5 * u).fill()
                let initial = Ink.text(SevenDayBurn.Day(date: day.date, tokens: day.tokens, costUsd: 0).weekdayInitial,
                                       SaverFonts.mono(12 * u), SaverPalette.tertiary)
                initial.draw(at: NSPoint(x: x + (barWidth - initial.size().width) / 2, y: chart.minY - 22 * u))
            }
        }

        // Live feed.
        let feedRect = NSRect(x: week.maxX + gap, y: grid.minY, width: columnWidth, height: bottomHeight)
        Ink.card(feedRect, u)
        var fy = feedRect.maxY - pad
        fy -= Ink.draw(Ink.label(live ? "Live" : "Live  ·  waiting", u, live ? SaverPalette.brand : SaverPalette.tertiary),
                       topLeft: NSPoint(x: feedRect.minX + pad, y: fy)).height + 14 * u
        if feed.isEmpty {
            Ink.draw(Ink.text("Responses appear here as they land", SaverFonts.mono(13 * u), SaverPalette.tertiary),
                     topLeft: NSPoint(x: feedRect.minX + pad, y: fy))
        }
        for (index, item) in feed.enumerated() {
            guard fy - 30 * u > feedRect.minY + pad / 2 else { break }
            let colour = index == 0 ? SaverPalette.text : SaverPalette.secondary
            let name = item.source == "codex" ? "Codex" : "Claude Code"
            Ink.draw(Ink.text(name, SaverFonts.sans(16 * u), colour), topLeft: NSPoint(x: feedRect.minX + pad, y: fy))
            let amount = Ink.text("+\(Ink.tokens(item.tokens))", SaverFonts.mono(14 * u), colour)
            Ink.draw(amount, topLeft: NSPoint(x: feedRect.maxX - pad - amount.size().width, y: fy))
            fy -= 34 * u
        }
    }
}

// MARK: - Leaderboard

/// Today's board on lines shipped, your rank and the gap to the next person, with Garry.
final class LeaderboardStyleView: NSView, SaverStyleView {
    private var snapshot: ScreensaverSnapshot?
    private var rate = 0.0
    private var live = false
    private let garry: NSImage? = Bundle(for: LeaderboardStyleView.self).image(forResource: "garry-cheer")

    override var isOpaque: Bool { true }

    func update(snapshot: ScreensaverSnapshot?, rate: Double, live: Bool) {
        guard snapshot != self.snapshot || rate != self.rate || live != self.live else { return }
        self.snapshot = snapshot
        self.rate = rate
        self.live = live
        needsDisplay = true
    }

    func liveEvent(tokens: Int, source: String, kind: String) {}

    override func draw(_ dirtyRect: NSRect) {
        SaverPalette.background.setFill()
        bounds.fill()
        let u = min(bounds.height / 900, bounds.width / 1500)
        let margin = 100 * u
        let area = bounds.insetBy(dx: (bounds.width - min(bounds.width - 2 * margin, 1500 * u)) / 2, dy: margin)
        let listWidth = area.width * 0.56
        var y = area.maxY
        y -= Ink.draw(Ink.label("LobsterOne  ·  today  ·  \(snapshot?.leaderboard?.metric ?? "lines shipped")", u, SaverPalette.brand),
                      topLeft: NSPoint(x: area.minX, y: y)).height + 34 * u

        guard let board = snapshot?.leaderboard, !board.entries.isEmpty else {
            Ink.draw(Ink.text("Today's board appears after LobsterOne's next update.", SaverFonts.sans(28 * u, .light), SaverPalette.secondary),
                     topLeft: NSPoint(x: area.minX, y: y))
            Ink.draw(Ink.text("It needs you signed in to LobsterOne in the menu bar.", SaverFonts.mono(14 * u), SaverPalette.tertiary),
                     topLeft: NSPoint(x: area.minX, y: y - 50 * u))
            return
        }

        // The list.
        let top = max(board.entries.map(\.value).max() ?? 1, 1)
        let rowHeight = min(64 * u, (y - area.minY) / CGFloat(max(board.entries.count, 1)))
        for entry in board.entries {
            let row = NSRect(x: area.minX, y: y - rowHeight, width: listWidth, height: rowHeight - 8 * u)
            if entry.isYou {
                SaverPalette.track.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: -14 * u, dy: 0), xRadius: 10 * u, yRadius: 10 * u).fill()
            }
            let baseline = row.midY + 11 * u
            Ink.draw(Ink.text("\(entry.rank)", SaverFonts.mono(17 * u), SaverPalette.tertiary), topLeft: NSPoint(x: row.minX, y: baseline))
            let name = entry.isYou ? "you" : String(entry.name.prefix(18))
            Ink.draw(Ink.text(name, SaverFonts.sans(21 * u, entry.isYou ? .medium : .regular), SaverPalette.text),
                     topLeft: NSPoint(x: row.minX + 56 * u, y: baseline + 2 * u))
            let value = Ink.text(Ink.tokens(Int(entry.value)), SaverFonts.mono(16 * u), SaverPalette.secondary)
            Ink.draw(value, topLeft: NSPoint(x: row.maxX - value.size().width, y: baseline))
            let bar = NSRect(x: row.minX + 290 * u, y: row.midY - 3 * u, width: row.width - 290 * u - 150 * u, height: 6 * u)
            SaverPalette.track.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3 * u, yRadius: 3 * u).fill()
            (entry.isYou ? SaverPalette.brand : SaverPalette.bar).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * CGFloat(entry.value / top)), height: bar.height),
                         xRadius: 3 * u, yRadius: 3 * u).fill()
            y -= rowHeight
        }

        // Your rank.
        let side = NSRect(x: area.minX + listWidth + 90 * u, y: area.minY, width: area.maxX - area.minX - listWidth - 90 * u, height: area.height - 60 * u)
        var sy = side.maxY - 10 * u
        sy -= Ink.draw(Ink.label("Your rank", u), topLeft: NSPoint(x: side.minX, y: sy)).height + 4 * u
        let rank = board.yourRank.map { "#\($0)" } ?? "—"
        sy -= Ink.draw(Ink.text(rank, SaverFonts.sans(170 * u, .light), SaverPalette.text), topLeft: NSPoint(x: side.minX, y: sy)).height + 6 * u
        let gapText: String
        if let rank = board.yourRank, let mine = board.yourValue {
            if rank == 1 {
                gapText = "Top of the board today"
            } else if let ahead = board.entries.first(where: { $0.rank == rank - 1 }) {
                gapText = "\(Ink.tokens(Int(ahead.value - mine))) lines to pass \(ahead.name.prefix(18))"
            } else {
                gapText = "of \(board.totalUsers) today"
            }
        } else {
            gapText = "Ship some code to get on today's board"
        }
        sy -= Ink.draw(Ink.text(gapText, SaverFonts.mono(15 * u), SaverPalette.secondary), topLeft: NSPoint(x: side.minX, y: sy)).height + 40 * u
        if let snapshot {
            sy -= Ink.draw(Ink.label("Tokens today", u), topLeft: NSPoint(x: side.minX, y: sy)).height + 4 * u
            sy -= Ink.draw(Ink.text(Ink.tokens(snapshot.tokens), SaverFonts.sans(40 * u, .light), SaverPalette.text), topLeft: NSPoint(x: side.minX, y: sy)).height + 2 * u
            Ink.draw(Ink.text(Ink.rate(rate, live: live), SaverFonts.mono(13 * u), SaverPalette.secondary), topLeft: NSPoint(x: side.minX, y: sy))
        }

        if let garry, let rep = garry.representations.first {
            NSGraphicsContext.current?.imageInterpolation = .none
            let scale = floor(2.2 * u * 2) / 2
            let size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
            garry.draw(in: NSRect(x: side.maxX - size.width, y: area.minY - 30 * u, width: size.width, height: size.height))
        }
    }
}

// MARK: - Matrix

/// Columns of glyphs falling down the screen. Every response lights a column, longer for
/// more tokens; with nothing happening the rain thins and slows.
///
/// Each fall is one Core Animation animation, interpolated by the render server at the
/// display's refresh rate. The saver only touches a column when its fall ends or a response
/// lights it, so the main thread is idle in between.
final class MatrixStyleView: NSView, SaverStyleView {
    private final class Column {
        let layer: CALayer
        /// "+1.2K" under the head of a live column, falling with it.
        let label = CATextLayer()
        let x: CGFloat
        var endsAt: CFTimeInterval = 0
        var tint: Tint?

        init(layer: CALayer, x: CGFloat) {
            self.layer = layer
            self.x = x
            layer.addSublayer(label)
        }
    }

    /// What a live column stands for, by colour: red-orange answers, amber tool calls, cyan
    /// file edits.
    enum Tint: String, CaseIterable {
        case answer, tool, edit

        /// Head, the two glyphs behind it, the trail (also the glow), and the token label.
        var colours: (head: NSColor, near: NSColor, trail: NSColor, label: NSColor) {
            switch self {
            case .answer:
                (NSColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 1), NSColor(srgbRed: 1, green: 0.72, blue: 0.55, alpha: 1),
                 NSColor(srgbRed: 1, green: 0.36, blue: 0.12, alpha: 1), NSColor(srgbRed: 1, green: 0.62, blue: 0.42, alpha: 1))
            case .tool:
                (NSColor(srgbRed: 1, green: 0.98, blue: 0.88, alpha: 1), NSColor(srgbRed: 1, green: 0.86, blue: 0.5, alpha: 1),
                 NSColor(srgbRed: 1, green: 0.69, blue: 0.13, alpha: 1), NSColor(srgbRed: 1, green: 0.8, blue: 0.4, alpha: 1))
            case .edit:
                (NSColor(srgbRed: 0.92, green: 1, blue: 1, alpha: 1), NSColor(srgbRed: 0.6, green: 0.93, blue: 1, alpha: 1),
                 NSColor(srgbRed: 0.18, green: 0.78, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.55, green: 0.88, blue: 1, alpha: 1))
            }
        }
    }

    /// One live column per this many tokens of a response, up to `burstCap`.
    private static let tokensPerColumn = 150
    private static let burstCap = 16
    /// Live columns on screen at once, so a huge response cannot paint the whole screen.
    private static let liveCap = 40
    /// Between responses, one live column per this many tokens of the last minute's rate.
    private static let streamTokensPerColumn = 400
    private static let lengths = [6, 10, 14, 20, 28]
    /// Several renderings per length, so neighbouring columns do not repeat each other.
    private static let variants = 5
    private var columns: [Column] = []
    private var dimStrips: [Int: [CGImage]] = [:]
    private var hotStrips: [Tint: [Int: [CGImage]]] = [:]
    private var glyph: CGFloat = 0
    private let overlay = MatrixOverlay()
    /// 0 when quiet, 1 at about 20K tokens a minute and above.
    private var activity = 0.0
    private var rate = 0.0
    private var live = false
    private var lastTint: Tint = .answer
    private var streamCredit = 0.0
    private var lastTick: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = SaverPalette.background.cgColor
        layer?.masksToBounds = true
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed || columns.isEmpty { rebuild() }
    }

    func update(snapshot: ScreensaverSnapshot?, rate: Double, live: Bool) {
        activity = rate > 0 ? min(1, log10(max(rate, 10)) / log10(20_000)) : 0
        self.rate = rate
        self.live = live
        overlay.update(snapshot: snapshot, rate: rate, live: live)
    }

    /// A burst: about one column per 150 tokens, launched a beat apart in nearby columns,
    /// with the token count under the first.
    func liveEvent(tokens: Int, source: String, kind: String) {
        overlay.noteActivity()
        guard !columns.isEmpty else { return }
        let tint = Tint(rawValue: kind) ?? .answer
        lastTint = tint
        let now = CACurrentMediaTime()
        let liveNow = columns.filter { $0.tint != nil && $0.endsAt > now }.count
        let wanted = min(Self.burstCap, max(1, Int((Double(tokens) / Double(Self.tokensPerColumn)).rounded(.up))))
        let count = max(1, min(wanted, Self.liveCap - liveNow))

        // Nearby columns, preferring ones between falls so running ones are not cut short.
        let centre = Int.random(in: 0..<columns.count)
        let span = max(count * 2, 8)
        let nearby = (max(0, centre - span)...min(columns.count - 1, centre + span)).shuffled()
        let picks = (nearby.filter { columns[$0].endsAt < now + 0.2 } + nearby).reduce(into: [Int]()) { picked, index in
            if picked.count < count, !picked.contains(index) { picked.append(index) }
        }
        for (order, index) in picks.enumerated() {
            let length = [10, 14, 20].randomElement() ?? 14
            fall(columns[index], length: length, tint: tint, delay: Double(order) * 0.09 + Double.random(in: 0...0.05),
                 label: order == 0 ? tokens : nil)
        }
    }

    /// Restarts columns whose fall has ended, and keeps live columns trickling in between
    /// responses at the last minute's rate. The falls themselves run on the GPU.
    func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 0 : min(now - lastTick, 0.5)
        lastTick = now
        overlay.tick()

        if live, rate > 0 {
            streamCredit += rate / 60 / Double(Self.streamTokensPerColumn) * dt
            if streamCredit >= 1 {
                streamCredit -= 1
                let idle = columns.indices.filter { columns[$0].endsAt < now }
                if let index = idle.randomElement(), columns.filter({ $0.tint != nil && $0.endsAt > now }).count < Self.liveCap {
                    fall(columns[index], length: [10, 14].randomElement() ?? 10, tint: lastTint, delay: 0, label: nil)
                }
            }
        } else {
            streamCredit = 0
        }

        for column in columns where column.endsAt <= now {
            let length = Self.lengths.randomElement() ?? 10
            // Quiet screens leave longer gaps between falls.
            let gap = Double.random(in: 0...(1.0 + 5.0 * (1 - activity)))
            fall(column, length: length, tint: nil, delay: gap, label: nil)
        }
    }

    /// Live columns are drawn wider than their slot, so their glow has room.
    private var glowPad: CGFloat { (glyph * 0.45).rounded() }

    private func fall(_ column: Column, length: Int, tint: Tint?, delay: CFTimeInterval, label tokens: Int?) {
        let hot = tint != nil
        let strips = (tint.flatMap { hotStrips[$0] } ?? dimStrips)[length] ?? []
        guard !strips.isEmpty else { return }
        let height = CGFloat(length) * glyph
        let top = bounds.height
        let bottom = -height
        // Points per second: hot columns race, the rest drift faster as activity rises.
        // Live columns fall a little faster than the rain but slowly enough to read.
        let speed = hot ? glyph * 9 : glyph * CGFloat.random(in: 3...8) * CGFloat(0.5 + 0.5 * activity)
        let duration = CFTimeInterval((top - bottom) / speed)
        let begin = CACurrentMediaTime() + delay

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        column.layer.removeAllAnimations()
        column.layer.contents = strips.randomElement()
        let pad = hot ? glowPad : 0
        column.layer.bounds = CGRect(x: 0, y: 0, width: glyph + 2 * pad, height: height)
        column.layer.position.x = column.x - pad
        column.layer.zPosition = hot ? 1 : 0
        column.layer.opacity = hot ? 1 : 0.7
        column.label.isHidden = tokens == nil
        if let tint, let tokens {
            let size = glyph * 0.62
            let amount = tokens < 1000 ? "\(tokens)" : String(format: "%.1fK", Double(tokens) / 1000)
            column.label.string = NSAttributedString(string: "+\(amount)", attributes: [
                .font: SaverFonts.mono(size, .semibold), .foregroundColor: tint.colours.label])
            column.label.alignmentMode = .center
            column.label.contentsScale = window?.backingScaleFactor ?? 2
            column.label.frame = CGRect(x: pad + glyph / 2 - glyph * 2.5, y: -size * 1.6, width: glyph * 5, height: size * 1.4)
        }
        // The model value is where the fall ends; the animation covers the way there.
        column.layer.position.y = bottom
        let animation = CABasicAnimation(keyPath: "position.y")
        animation.fromValue = top
        animation.toValue = bottom
        animation.duration = duration
        animation.beginTime = begin
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        column.layer.add(animation, forKey: "fall")
        CATransaction.commit()

        column.tint = tint
        column.endsAt = begin + duration
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        columns.forEach { $0.layer.removeFromSuperlayer() }
        columns = []
        glyph = max(10, (min(bounds.height / 900, bounds.width / 1500) * 22).rounded())
        let scale = window?.backingScaleFactor ?? 2
        for length in Self.lengths {
            dimStrips[length] = (0..<Self.variants).compactMap { _ in Self.strip(length: length, glyph: glyph, scale: scale, tint: nil) }
            for tint in Tint.allCases {
                hotStrips[tint, default: [:]][length] = (0..<Self.variants).compactMap { _ in
                    Self.strip(length: length, glyph: glyph, scale: scale, tint: tint, pad: glowPad)
                }
            }
        }
        let now = CACurrentMediaTime()
        for index in 0..<Int(bounds.width / glyph) {
            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.contentsGravity = .resize
            layer.position = CGPoint(x: CGFloat(index) * glyph, y: -bounds.height)
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "zPosition": NSNull()]
            self.layer?.insertSublayer(layer, below: overlay.layer)
            let column = Column(layer: layer, x: CGFloat(index) * glyph)
            column.label.isHidden = true
            column.label.actions = ["string": NSNull(), "contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
            // Stagger the first falls so the screen does not start as one wall.
            column.endsAt = now + Double.random(in: 0...3)
            columns.append(column)
        }
        let u = min(bounds.height / 900, bounds.width / 1500)
        overlay.frame = NSRect(x: 90 * u, y: 80 * u, width: 640 * u, height: 250 * u)
        overlay.unit = u
    }

    /// A vertical run of glyphs, brightest at the bottom (the falling head).
    /// Live strips are bold, white-hot at the head and glowing; the glow is baked into the
    /// image, so it costs nothing per frame.
    private static func strip(length: Int, glyph: CGFloat, scale: CGFloat, tint: Tint?, pad: CGFloat = 0) -> CGImage? {
        let hot = tint != nil
        let width = Int((glyph + 2 * pad) * scale), height = Int(glyph * CGFloat(length) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let glyphs = Array("0123456789abcdef")
        let font = hot ? SaverFonts.mono(glyph * 0.8, .bold) : SaverFonts.mono(glyph * 0.72)
        let glow = NSShadow()
        glow.shadowBlurRadius = pad * 0.9
        glow.shadowOffset = .zero
        glow.shadowColor = (tint ?? .answer).colours.trail.withAlphaComponent(0.95)
        for index in 0..<length {
            // index 0 is the head, at the bottom.
            let t = CGFloat(index) / CGFloat(max(length - 1, 1))
            let colour: NSColor
            if let tint {
                let palette = tint.colours
                switch index {
                case 0: colour = palette.head
                case 1, 2: colour = palette.near
                default: colour = palette.trail.withAlphaComponent(1 - 0.7 * t)
                }
            } else {
                colour = index == 0
                    ? NSColor(srgbRed: 0.66, green: 0.64, blue: 0.62, alpha: 0.9)
                    : NSColor(srgbRed: 0.33, green: 0.28, blue: 0.24, alpha: 0.9 - 0.7 * t)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            if hot { attributes[.shadow] = glow }
            let character = NSAttributedString(string: String(glyphs.randomElement()!), attributes: attributes)
            let size = character.size()
            character.draw(at: NSPoint(x: pad + (glyph - size.width) / 2, y: CGFloat(index) * glyph + (glyph - size.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// The figures panel over the rain. So that no bright text sits on the same pixels for long,
/// it cycles through four figures with a cross-fade, and dims, then hides, when nothing has
/// happened for a while. Both fades run on the GPU.
private final class MatrixOverlay: NSView {
    enum Page: CaseIterable {
        case today, rate, session, week
    }

    /// How long each figure stays up.
    static let pageDuration: CFTimeInterval = 20
    /// Without activity for this long the panel dims to half, then hides until the next response.
    static let dimAfter: CFTimeInterval = 10 * 60
    static let hideAfter: CFTimeInterval = 30 * 60

    var unit: CGFloat = 1 { didSet { needsDisplay = true } }
    private(set) var page: Page = .today
    private var snapshot: ScreensaverSnapshot?
    private var rate = 0.0
    private var live = false
    private var pageShownAt = CACurrentMediaTime()
    private var lastActivity = CACurrentMediaTime()
    private var brightness: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func update(snapshot: ScreensaverSnapshot?, rate: Double, live: Bool) {
        if rate > 0 { noteActivity() }
        guard snapshot != self.snapshot || rate != self.rate || live != self.live else { return }
        self.snapshot = snapshot
        self.rate = rate
        self.live = live
        needsDisplay = true
    }

    /// A response landed, or the rate says work is happening: back to full brightness.
    func noteActivity() {
        lastActivity = CACurrentMediaTime()
        fade(to: 1, over: 0.6)
    }

    /// Called every frame; does nothing most of the time.
    func tick() {
        let now = CACurrentMediaTime()
        if now - pageShownAt >= Self.pageDuration {
            pageShownAt = now
            advance()
        }
        let idle = now - lastActivity
        if idle >= Self.hideAfter {
            fade(to: 0, over: 4)
        } else if idle >= Self.dimAfter {
            fade(to: 0.5, over: 4)
        }
    }

    private func advance() {
        let pages = Page.allCases.filter(isAvailable)
        guard let index = pages.firstIndex(of: page) else {
            page = pages.first ?? .today
            needsDisplay = true
            return
        }
        page = pages[(index + 1) % pages.count]
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.9
        layer?.add(fade, forKey: "page")
        needsDisplay = true
    }

    /// Pages without data are skipped.
    private func isAvailable(_ page: Page) -> Bool {
        guard let snapshot else { return page == .today }
        switch page {
        case .today, .rate: return true
        case .session: return snapshot.percentUsed > 0 || snapshot.resetsAt != nil
        case .week: return !snapshot.sevenDay.isEmpty
        }
    }

    private func fade(to level: CGFloat, over duration: TimeInterval) {
        guard level != brightness else { return }
        brightness = level
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = level
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let u = unit
        SaverPalette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14 * u, yRadius: 14 * u).fill()
        var y = bounds.maxY - 24 * u
        y -= Ink.draw(Ink.label("LobsterOne", u, SaverPalette.brand), topLeft: NSPoint(x: 26 * u, y: y)).height + 4 * u
        guard let snapshot else { return }

        let figure: String, caption: String
        switch page {
        case .today:
            figure = Ink.tokens(snapshot.tokens)
            caption = "Tokens today"
        case .rate:
            figure = rate > 0 ? SevenDayBurn.formatTokens(Int(rate)) : "0"
            caption = rate > 0 ? "Tokens a minute\(live ? "  ·  live" : "")" : "Quiet right now"
        case .session:
            let percent = Int(min(max(snapshot.percentUsed, 0), 100).rounded())
            figure = "\(snapshot.isRealQuota ? "" : "~")\(percent)%"
            var text = "Session used"
            if let resets = snapshot.resetsAt, resets > Date() {
                let minutes = Int(resets.timeIntervalSinceNow / 60)
                text += minutes >= 60 ? "  ·  resets in \(minutes / 60)h \(minutes % 60)m" : "  ·  resets in \(max(minutes, 1))m"
            }
            caption = text
        case .week:
            figure = SevenDayBurn.formatTokens(snapshot.sevenDay.reduce(0) { $0 + max(0, $1.tokens) })
            caption = "Tokens in the last 7 days"
        }
        y -= Ink.draw(Ink.text(figure, SaverFonts.sans(100 * u, .light), SaverPalette.text), topLeft: NSPoint(x: 22 * u, y: y)).height
        y -= Ink.draw(Ink.label(caption, u, SaverPalette.secondary), topLeft: NSPoint(x: 26 * u, y: y)).height + 14 * u

        // The key to the live colours.
        var x = 26 * u
        for (tint, name) in [(MatrixStyleView.Tint.answer, "answers"), (.tool, "tool calls"), (.edit, "edits")] {
            tint.colours.trail.setFill()
            NSRect(x: x, y: y - 11 * u, width: 9 * u, height: 9 * u).fill()
            x += 16 * u
            x += Ink.draw(Ink.label(name, u, SaverPalette.secondary), topLeft: NSPoint(x: x, y: y)).width + 26 * u
        }
    }
}
