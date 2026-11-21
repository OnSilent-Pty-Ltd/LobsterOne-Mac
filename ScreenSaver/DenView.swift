import AppKit
import ImageIO
import QuartzCore

/// Garry at his den, hauling shells in from a pile. With live events from the app, each model
/// response drops one shell the moment it happens; otherwise shells sink at a pace set by the
/// polled tokens per minute, and he carries them in one at a time. When tokens
/// arrive faster than he can haul, the pile grows; when nothing is happening the neon sign
/// goes dark and he stands still.
///
/// Pure state, stepped with a fixed `dt`, so it behaves the same at any frame rate.
struct DenScene {
    /// Logical size. Origin bottom-left, like AppKit.
    static let size = CGSize(width: 900, height: 460)
    static let ground: CGFloat = 78
    static let pileCapacity = 12
    static let shellKinds = 8

    static let denMouth = CGPoint(x: 311, y: ground + 28)
    /// In front of the den door, clear of the sign post.
    static let lobsterHome: CGFloat = 372
    static let lobsterAtPile: CGFloat = 612
    static let pileCenter: CGFloat = 776

    enum Phase: Equatable {
        case idle
        case toPile
        case picking(TimeInterval)
        case toDen
        case stowing(TimeInterval)
        /// A moment of triumph when the pile is cleared.
        case cheering(TimeInterval)
    }

    struct FallingShell {
        var slot: Int
        var kind: Int
        var x: CGFloat
        var y: CGFloat
        var phase: Double
    }

    struct Bubble {
        var x: CGFloat
        var y: CGFloat
        var born: TimeInterval
    }

    /// A little kick of sand where a shell lands.
    struct Puff {
        var x: CGFloat
        var y: CGFloat
        var born: TimeInterval
    }

    /// Zero means quiet.
    var tokensPerMinute: Double = 0
    /// True while live events are arriving: shells come from `drop()`, not from the rate.
    var liveMode = false

    private(set) var phase: Phase = .idle
    private(set) var lobsterX: CGFloat = lobsterHome
    private(set) var facingLeft = false
    /// Which shell he has in his claws, if any.
    private(set) var carrying: Int?
    /// Shell kinds resting on the pile, bottom slot first.
    private(set) var pile: [Int] = []
    private(set) var falling: [FallingShell] = []
    private(set) var bubbles: [Bubble] = []
    private(set) var puffs: [Puff] = []
    private(set) var time: TimeInterval = 0
    private var untilNextShell: TimeInterval = 1.5
    private var untilNextBubble: TimeInterval = 0.8
    private var dropped = 0
    private var litSince: TimeInterval?

    var isBusy: Bool { tokensPerMinute > 0 }
    var isWalking: Bool { phase == .toPile || phase == .toDen }
    /// False when a frame would look identical to the last one.
    var isAnimating: Bool {
        isBusy || phase != .idle || !pile.isEmpty || !falling.isEmpty || !bubbles.isEmpty || !puffs.isEmpty
    }
    /// Nothing to do and nothing coming: he dozes off by the door.
    var isAsleep: Bool { !isBusy && phase == .idle && pile.isEmpty && falling.isEmpty }
    /// The moment work starts, while the sign is still stuttering on.
    var isWaking: Bool { phase == .idle && litSince.map { time - $0 < 0.72 } == true }
    /// True once he has hold of the shell he is bending for.
    var hasGrip: Bool { if case .picking = phase { return carrying != nil }; return false }
    /// A short blink every few seconds while he waits.
    var isBlinking: Bool { phase == .idle && time.truncatingRemainder(dividingBy: 3.6) < 0.16 }

    /// The neon sign stutters on when work starts, and drops out for a moment now and then.
    var signOn: Bool {
        guard isBusy, let litSince else { return false }
        let age = time - litSince
        if age < 0.72 { return Int(age / 0.09) % 2 == 1 }
        return time.truncatingRemainder(dividingBy: 23) > 0.1
    }

    /// 0 to 1 while a shell slides from his claws into the den.
    var stowProgress: Double? {
        if case .stowing(let elapsed) = phase { return min(elapsed / Self.stowTime, 1) }
        return nil
    }

    private static let pickTime: TimeInterval = 0.5
    private static let cheerTime: TimeInterval = 0.7
    private static let stowTime: TimeInterval = 0.45
    static let puffLife: TimeInterval = 0.4

    /// Shells arriving per minute. Logarithmic, because token rates span three orders of
    /// magnitude: about 4 a minute at 1K tok/min, 18 at 10K, 32 at 100K.
    static func shellsPerMinute(tokensPerMinute rate: Double) -> Double {
        guard rate > 0 else { return 0 }
        return min(max(4 + 14 * log10(max(rate, 1) / 1000), 3), 40)
    }

    /// Where shell number `slot` rests: rows of 5, 4 and 3.
    static func slotPosition(_ slot: Int) -> CGPoint {
        let rows = [5, 4, 3]
        var index = slot, row = 0
        while row < rows.count - 1, index >= rows[row] {
            index -= rows[row]
            row += 1
        }
        let spacing: CGFloat = 46
        let x = pileCenter + (CGFloat(index) - CGFloat(rows[row] - 1) / 2) * spacing
        return CGPoint(x: x, y: ground + CGFloat(row) * 30)
    }

    mutating func step(_ dt: TimeInterval) {
        time += dt
        if isBusy {
            if litSince == nil { litSince = time }
        } else {
            litSince = nil
        }
        dropShells(dt)
        moveLobster(dt)
        blowBubbles(dt)
        puffs.removeAll { time - $0.born > Self.puffLife }
    }

    /// One shell starts falling now, unless the pile is full.
    mutating func drop() {
        let slot = pile.count + falling.count
        guard slot < Self.pileCapacity else { return }
        // Steps of 5 walk through all 8 kinds before repeating.
        let kind = (dropped * 5 + 3) % Self.shellKinds
        dropped += 1
        falling.append(FallingShell(slot: slot, kind: kind, x: Self.slotPosition(slot).x,
                                    y: Self.size.height + 30, phase: time))
    }

    private mutating func dropShells(_ dt: TimeInterval) {
        let perMinute = liveMode ? 0 : Self.shellsPerMinute(tokensPerMinute: tokensPerMinute)
        if perMinute > 0 {
            untilNextShell -= dt
            if untilNextShell <= 0 {
                untilNextShell += 60 / perMinute
                drop()
            }
        }

        for index in falling.indices { falling[index].y -= 150 * dt }
        // Shells land in the order they were dropped, so the first one is always the lowest.
        while let first = falling.first, first.y <= Self.slotPosition(first.slot).y {
            falling.removeFirst()
            pile.append(first.kind)
            let rest = Self.slotPosition(first.slot)
            puffs.append(Puff(x: rest.x, y: rest.y, born: time))
        }
    }

    private mutating func moveLobster(_ dt: TimeInterval) {
        // He hurries when the pile backs up.
        let speed = 120 * (1 + 0.3 * CGFloat(min(pile.count, 8)))

        switch phase {
        case .idle:
            if !pile.isEmpty {
                phase = .toPile
                facingLeft = false
            }
        case .toPile:
            lobsterX = min(lobsterX + speed * dt, Self.lobsterAtPile)
            if lobsterX >= Self.lobsterAtPile { phase = .picking(0) }
        case .picking(let elapsed):
            // He reaches for the first half, then has it. Something has landed or he would
            // not have set off, and only he removes shells.
            if carrying == nil, elapsed + dt >= Self.pickTime / 2 { carrying = pile.popLast() }
            if elapsed + dt >= Self.pickTime {
                facingLeft = true
                phase = .toDen
            } else {
                phase = .picking(elapsed + dt)
            }
        case .toDen:
            lobsterX = max(lobsterX - speed * dt, Self.lobsterHome)
            if lobsterX <= Self.lobsterHome { phase = .stowing(0) }
        case .stowing(let elapsed):
            if elapsed + dt >= Self.stowTime {
                carrying = nil
                facingLeft = false
                phase = pile.isEmpty && falling.isEmpty ? .cheering(0) : .idle
            } else {
                phase = .stowing(elapsed + dt)
            }
        case .cheering(let elapsed):
            phase = elapsed + dt >= Self.cheerTime || !pile.isEmpty ? .idle : .cheering(elapsed + dt)
        }
    }

    /// The den breathes out a bubble every couple of seconds while there is work on.
    private mutating func blowBubbles(_ dt: TimeInterval) {
        if isBusy {
            untilNextBubble -= dt
            if untilNextBubble <= 0 {
                // Uneven gaps and start points, repeatable without a random source.
                let n = Double(bubbles.count) + time
                untilNextBubble += 1.6 + 1.3 * abs(sin(n * 1.7))
                bubbles.append(Bubble(x: Self.denMouth.x - 14 + 28 * CGFloat(abs(sin(n * 2.3))),
                                      y: Self.denMouth.y + 26, born: time))
            }
        }
        for index in bubbles.indices { bubbles[index].y += 44 * dt }
        bubbles.removeAll { $0.y > Self.size.height - 30 }
    }
}

/// Shows a `DenScene`, scaled to fill the view. Garry, the shells and the plants are true
/// pixel art on one grid (see Sprites/README.md); the den is the web game's original. The
/// sand, shadows, sign glow, bubbles and sand puffs are made here on that same grid.
///
/// Everything is a Core Animation layer, so a frame is a handful of position and image
/// changes that the graphics card composites. Drawing the scene into the view each frame
/// instead cost about 14% of a core across two displays, nearly all of it re-uploading the
/// picture.
final class DenView: NSView {
    var scene = DenScene()
    /// Screen points per layout unit, so the caption matches the labels beside it.
    var unit: CGFloat = 1
    var caption = ""
    /// Off in the small preview, where the caption would be a few pixels high.
    var showsCaption = true
    /// Time spent updating layers, so the host log can show what a frame costs.
    private(set) var drawSeconds: CFTimeInterval = 0
    private(set) var drawCount = 0

    /// Scene units per sprite pixel.
    private static let pixel: CGFloat = 1.57
    /// Garry's frames share a 160 x 132 canvas with his cap centred on this column.
    private static let garryAnchor: CGFloat = 76
    private static let garryCanvas = CGSize(width: 160, height: 132)
    /// Where his claws hold a shell in each pose, in canvas pixels from the top-left.
    /// Printed by tools/main.swift.
    private static let holdCarrying = CGPoint(x: 85.2, y: 81.3)
    private static let holdGripping = CGPoint(x: 94.5, y: 113.5)
    private static let holdPushing = CGPoint(x: 101.3, y: 113.4)
    /// The sign board inside the den sprite, in scene units from the image's bottom-left.
    private static let signBoard = CGRect(x: 371, y: 163, width: 151, height: 46)
    /// How far below the sea floor the den image starts: its art has 47 empty rows under the
    /// rocks (37.6 units at this scale), and a little more so the uneven base beds into the sand.
    private static let denSunk: CGFloat = 43.6
    private static let denScale: CGFloat = 0.8
    private static let kelpBandRows = 8

    private enum Tint {
        static let sand = NSColor(srgbRed: 0x5A / 255, green: 0x4C / 255, blue: 0x40 / 255, alpha: 1)
        static let sandDark = NSColor(srgbRed: 0x3A / 255, green: 0x31 / 255, blue: 0x2A / 255, alpha: 1)
        static let pebble = NSColor(srgbRed: 0x7C / 255, green: 0x6A / 255, blue: 0x58 / 255, alpha: 1)
        static let shadow = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34)
        static let neon = NSColor(srgbRed: 0x2E / 255, green: 0xC8 / 255, blue: 0xF0 / 255, alpha: 1)
        static let bubble = NSColor(srgbRed: 0x9A / 255, green: 0xD8 / 255, blue: 0xE8 / 255, alpha: 1)
    }

    /// Layers handed out in order each frame; whatever is left over is hidden.
    private final class Pool {
        let host = CALayer()
        private var layers: [CALayer] = []
        private var used = 0

        func begin() { used = 0 }

        func next() -> CALayer {
            if used == layers.count {
                let layer = DenView.pixelLayer()
                host.addSublayer(layer)
                layers.append(layer)
            }
            used += 1
            return layers[used - 1]
        }

        func end() {
            for layer in layers[used...] where !layer.isHidden { layer.isHidden = true }
        }
    }

    private let images: [String: CGImage]
    private var kelpBands: [(image: CGImage, start: Int, rows: Int)] = []
    /// The parts that only change with the sign, pre-rendered once per sign state and size.
    private var backdrops: [Bool: CGImage] = [:]
    private var backdropKey = ""
    private var captionKey = ""

    private let root = CALayer()
    private let backdropLayer = DenView.pixelLayer()
    private var kelpLayers: [CALayer] = []
    private let shadows = Pool()
    private var pileLayers: [CALayer] = []
    private let fallingShells = Pool()
    private let garryLayer = DenView.pixelLayer()
    private let carriedLayer = DenView.pixelLayer()
    private let effects = Pool()
    private let captionLayer = CATextLayer()

    private static func pixelLayer() -> CALayer {
        let layer = CALayer()
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.actions = instantChanges
        return layer
    }

    /// Movement is interpolated by the GPU between the scene's 15 steps a second (see
    /// `render(animated:)`); sprite swaps, colours and visibility stay instant so frames
    /// never cross-fade.
    private static let instantChanges: [String: any CAAction] = [
        "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull(),
    ]

    override init(frame: NSRect) {
        let bundle = Bundle(for: DenView.self)
        var names = ["den", "den_off", "kelp", "sea-fan", "garry-idle", "garry-blink", "garry-sleep",
                     "garry-cheer", "garry-wave", "garry-reach", "garry-grip", "garry-push"]
        names += (1...4).flatMap { ["garry-walk-\($0)", "garry-carry-\($0)-left"] }
        names.append("garry-push-left")
        names += (1...DenScene.shellKinds).map { "shell-\($0)" }
        var loaded: [String: CGImage] = [:]
        for name in names {
            if let url = bundle.url(forResource: name, withExtension: "png"),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                loaded[name] = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
        }
        images = loaded
        super.init(frame: frame)

        // The kelp sways in horizontal bands, so each band is its own strip of the image.
        if let kelp = loaded["kelp"] {
            for start in stride(from: 0, to: kelp.height, by: Self.kelpBandRows) {
                let rows = min(Self.kelpBandRows, kelp.height - start)
                // Rows are counted from the bottom; image coordinates run from the top.
                let strip = CGRect(x: 0, y: kelp.height - start - rows, width: kelp.width, height: rows)
                if let image = kelp.cropping(to: strip) { kelpBands.append((image, start, rows)) }
            }
        }

        root.backgroundColor = SaverPalette.background.cgColor
        root.masksToBounds = true
        root.addSublayer(backdropLayer)
        for _ in kelpBands {
            let layer = Self.pixelLayer()
            layer.opacity = 0.6
            kelpLayers.append(layer)
            root.addSublayer(layer)
        }
        root.addSublayer(shadows.host)
        for _ in 0..<DenScene.pileCapacity {
            let layer = Self.pixelLayer()
            layer.isHidden = true
            pileLayers.append(layer)
            root.addSublayer(layer)
        }
        root.addSublayer(fallingShells.host)
        root.addSublayer(garryLayer)
        carriedLayer.isHidden = true
        root.addSublayer(carriedLayer)
        root.addSublayer(effects.host)
        captionLayer.anchorPoint = .zero
        captionLayer.actions = ["string": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        backdropLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        root.addSublayer(captionLayer)

        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    // MARK: - Placing layers

    /// A layer coming back into view jumps to its place instead of sliding from its last one.
    private func appearing(_ layer: CALayer, _ frame: CGRect) {
        guard layer.frame != frame else { return }
        if layer.isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = frame
            CATransaction.commit()
        } else {
            layer.frame = frame
        }
    }

    /// Each setter is skipped when nothing changed, so a still scene commits nothing.
    private func place(_ layer: CALayer, _ image: CGImage?, _ frame: CGRect, alpha: CGFloat = 1) {
        if (layer.contents as AnyObject?) !== image { layer.contents = image }
        appearing(layer, frame)
        if layer.opacity != Float(alpha) { layer.opacity = Float(alpha) }
        if layer.isHidden { layer.isHidden = false }
    }

    private func fill(_ layer: CALayer, _ colour: NSColor, _ frame: CGRect, alpha: CGFloat = 1) {
        let cgColour = colour.cgColor
        if layer.backgroundColor != cgColour { layer.backgroundColor = cgColour }
        appearing(layer, frame)
        if layer.opacity != Float(alpha) { layer.opacity = Float(alpha) }
        if layer.isHidden { layer.isHidden = false }
    }

    private func hide(_ layer: CALayer) {
        if !layer.isHidden { layer.isHidden = true }
    }

    // MARK: - Rendering

    /// Brings the layers in line with `scene`. Call after stepping the scene or changing
    /// `unit`, `caption` or the frame.
    /// `animated` is for the scene's own steps: positions then glide over one step's length
    /// on the GPU instead of jumping 15 times a second.
    func render(animated: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let began = CACurrentMediaTime()
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(1.0 / 15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        defer {
            CATransaction.commit()
            drawSeconds += CACurrentMediaTime() - began
            drawCount += 1
        }

        let k = bounds.width / DenScene.size.width
        let ground = DenScene.ground
        let px = Self.pixel
        let floor = ground - 6
        let backing = window?.backingScaleFactor ?? 1

        /// The rectangle a sprite covers with its bottom-left corner at (`left`, `bottom`).
        func spriteRect(_ name: String, left: CGFloat, bottom: CGFloat, scale: CGFloat) -> CGRect {
            guard let image = images[name] else { return .zero }
            return CGRect(x: left * k, y: bottom * k,
                          width: CGFloat(image.width) * scale * k, height: CGFloat(image.height) * scale * k)
        }

        /// A shell centred on `centre`.
        func shellRect(_ kind: Int, centre: CGPoint, scale: CGFloat = px) -> CGRect {
            guard let image = images["shell-\(kind + 1)"] else { return .zero }
            let wide = CGFloat(image.width) * scale, high = CGFloat(image.height) * scale
            return CGRect(x: (centre.x - wide / 2) * k, y: (centre.y - high / 2) * k, width: wide * k, height: high * k)
        }

        /// A block in scene units, snapped to the sprite pixel grid.
        func blockRect(_ x: CGFloat, _ y: CGFloat, _ wide: CGFloat, _ high: CGFloat) -> CGRect {
            CGRect(x: (x / px).rounded() * px * k, y: (y / px).rounded() * px * k, width: wide * k, height: high * k)
        }

        // Backdrop: glow, sea fan, den and sand.
        let key = "\(bounds.size)@\(backing)"
        if key != backdropKey {
            backdropKey = key
            backdrops = [:]
        }
        let signOn = scene.signOn
        if backdrops[signOn] == nil {
            backdrops[signOn] = makeBackdrop(signOn: signOn, k: k, floor: floor, backing: backing)
        }
        place(backdropLayer, backdrops[signOn], bounds)

        // Kelp, swaying more towards the tips.
        if let kelp = images["kelp"] {
            let kelpLeft = 548 - CGFloat(kelp.width) * px / 2
            for (layer, band) in zip(kelpLayers, kelpBands) {
                let height = Double(band.start) / Double(max(kelp.height, 1))
                let lean = CGFloat((sin(scene.time * 1.1 + height * 2.2) * 2.2 * height).rounded())
                let frame = CGRect(x: (kelpLeft + lean * px) * k, y: (floor - 2 * px + CGFloat(band.start) * px) * k,
                                   width: CGFloat(kelp.width) * px * k, height: CGFloat(band.rows) * px * k)
                place(layer, band.image, frame, alpha: 0.6)
            }
        }

        // Shadows sit under what casts them.
        shadows.begin()
        for slot in scene.pile.indices where slot < 5 {
            fill(shadows.next(), Tint.shadow, blockRect(DenScene.slotPosition(slot).x - 13 * px, floor - px, 26 * px, px))
        }
        fill(shadows.next(), Tint.shadow, blockRect(scene.lobsterX - 30 * px, floor - px, 60 * px, px))
        fill(shadows.next(), Tint.shadow, blockRect(scene.lobsterX - 22 * px, floor - 2 * px, 44 * px, px), alpha: 0.6)
        shadows.end()

        for (slot, layer) in pileLayers.enumerated() {
            guard slot < scene.pile.count else { hide(layer); continue }
            let kind = scene.pile[slot], p = DenScene.slotPosition(slot)
            place(layer, images["shell-\(kind + 1)"], shellRect(kind, centre: CGPoint(x: p.x, y: p.y + 14)))
        }

        fallingShells.begin()
        for falling in scene.falling {
            let sway = CGFloat(sin((scene.time - falling.phase) * 2.4)) * 7
            place(fallingShells.next(), images["shell-\(falling.kind + 1)"],
                  shellRect(falling.kind, centre: CGPoint(x: falling.x + sway, y: falling.y + 14)))
        }
        fallingShells.end()

        // Garry. Walk and carry cycles step at the web game's pace, with a slight bounce.
        let step = Int(scene.time / 0.15) % 4 + 1
        let frame: String
        var hold = Self.holdCarrying
        var bounce: CGFloat = 0
        switch scene.phase {
        case .idle:
            if scene.isAsleep {
                frame = "garry-sleep"
            } else if scene.isWaking {
                frame = "garry-wave"
            } else {
                frame = scene.isBlinking ? "garry-blink" : "garry-idle"
            }
        case .toPile:
            frame = "garry-walk-\(step)"
            bounce = step % 2 == 0 ? px : 0
        case .picking:
            frame = scene.hasGrip ? "garry-grip" : "garry-reach"
            hold = Self.holdGripping
        case .toDen:
            frame = "garry-carry-\(step)-left"
            bounce = step % 2 == 0 ? px : 0
        case .stowing:
            frame = "garry-push-left"
            hold = Self.holdPushing
        case .cheering:
            frame = "garry-cheer"
            bounce = step % 2 == 0 ? 2 * px : 0
        }
        // Left-facing frames are already mirrored in the file, so only the anchor moves.
        let facingLeft = scene.facingLeft
        let anchor = facingLeft ? Self.garryCanvas.width - Self.garryAnchor : Self.garryAnchor
        let bottom = floor - 4 * px + bounce
        place(garryLayer, images[frame], spriteRect(frame, left: scene.lobsterX - anchor * px, bottom: bottom, scale: px))

        if let kind = scene.carrying {
            let side: CGFloat = facingLeft ? -1 : 1
            let claws = CGPoint(x: scene.lobsterX + side * (hold.x - Self.garryAnchor) * px,
                                y: bottom + (Self.garryCanvas.height - hold.y) * px)
            if let t = scene.stowProgress {
                // Slides into the den mouth and shrinks out of sight.
                let centre = CGPoint(x: claws.x + (DenScene.denMouth.x - claws.x) * t,
                                     y: claws.y + (DenScene.denMouth.y - claws.y) * t)
                place(carriedLayer, images["shell-\(kind + 1)"],
                      shellRect(kind, centre: centre, scale: px * (1 - 0.7 * t)), alpha: 1 - 0.6 * t)
            } else {
                place(carriedLayer, images["shell-\(kind + 1)"], shellRect(kind, centre: claws))
            }
        } else {
            hide(carriedLayer)
        }

        effects.begin()
        // Sand kicked up where a shell has just landed.
        for puff in scene.puffs {
            let t = CGFloat((scene.time - puff.born) / DenScene.puffLife)
            for (side, lift) in [(CGFloat(-1), CGFloat(1)), (1, 1), (-0.5, 1.8), (0.6, 1.6)] {
                fill(effects.next(), Tint.pebble,
                     blockRect(puff.x + side * (10 + 22 * t), puff.y - 4 + lift * 14 * t * (1.4 - t), px, px), alpha: 1 - t)
            }
        }
        if scene.isAsleep {
            let z = ["####", "..#.", ".#..", "####"]
            for (origin, size, alpha) in [(CGPoint(x: 34, y: 118), CGFloat(2), CGFloat(0.9)), (CGPoint(x: 58, y: 150), 3, 0.55)] {
                for (row, line) in z.enumerated() { for (column, mark) in line.enumerated() where mark == "#" {
                    fill(effects.next(), SaverPalette.secondary,
                         blockRect(scene.lobsterX + origin.x + CGFloat(column) * size * px,
                                   floor + origin.y - CGFloat(row) * size * px, size * px, size * px), alpha: alpha)
                } }
            }
        }
        // Bubbles from the den: a hollow square with a glint, fading as they rise.
        for bubble in scene.bubbles {
            let age = scene.time - bubble.born
            let rise = (bubble.y - DenScene.denMouth.y) / (DenScene.size.height - DenScene.denMouth.y)
            let alpha = max(0, 0.75 * (1 - rise))
            let x = bubble.x + CGFloat(sin(age * 2.6)) * 6, y = bubble.y
            let side: CGFloat = Int(bubble.born * 10) % 3 == 0 ? 4 : 3
            let edge = (side - 1) * px
            fill(effects.next(), Tint.bubble, blockRect(x, y, side * px, px), alpha: alpha)
            fill(effects.next(), Tint.bubble, blockRect(x, y + edge, side * px, px), alpha: alpha)
            fill(effects.next(), Tint.bubble, blockRect(x, y + px, px, edge - px), alpha: alpha)
            fill(effects.next(), Tint.bubble, blockRect(x + edge, y + px, px, edge - px), alpha: alpha)
            fill(effects.next(), .white, blockRect(x + px, y + (side - 2) * px, px, px), alpha: alpha)
        }
        effects.end()

        let wantedCaption = "\(caption)|\(unit)|\(backing)"
        if wantedCaption != captionKey {
            captionKey = wantedCaption
            let text = NSAttributedString(string: caption, attributes: [
                .font: SaverFonts.mono(12 * unit), .foregroundColor: SaverPalette.tertiary, .kern: 1.6 * unit,
            ])
            captionLayer.string = text
            captionLayer.contentsScale = backing
            captionLayer.bounds = CGRect(origin: .zero, size: CGSize(width: ceil(text.size().width) + 2, height: ceil(text.size().height)))
        }
        if captionLayer.isHidden == showsCaption { captionLayer.isHidden = !showsCaption }
        let captionAt = CGPoint(x: 0, y: max(0, (ground - 46) * k))
        if captionLayer.position != captionAt { captionLayer.position = captionAt }
    }

    /// Scaling the den art and laying ~900 sand blocks is the expensive part of the picture,
    /// and none of it moves.
    private func makeBackdrop(signOn: Bool, k: CGFloat, floor: CGFloat, backing: CGFloat) -> CGImage? {
        let px = Self.pixel
        guard let context = CGContext(
            data: nil, width: Int((bounds.width * backing).rounded(.up)), height: Int((bounds.height * backing).rounded(.up)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: backing, y: backing)
        context.interpolationQuality = .none

        func block(_ x: CGFloat, _ y: CGFloat, _ wide: CGFloat, _ high: CGFloat, _ colour: NSColor, alpha: CGFloat = 1) {
            context.setFillColor(colour.withAlphaComponent(colour.alphaComponent * alpha).cgColor)
            context.fill(CGRect(x: (x / px).rounded() * px * k, y: (y / px).rounded() * px * k, width: wide * k, height: high * k))
        }
        func sprite(_ name: String, left: CGFloat, bottom: CGFloat, scale: CGFloat, alpha: CGFloat = 1) {
            guard let image = images[name] else { return }
            context.saveGState()
            context.setAlpha(alpha)
            context.draw(image, in: CGRect(x: left * k, y: bottom * k,
                                           width: CGFloat(image.width) * scale * k, height: CGFloat(image.height) * scale * k))
            context.restoreGState()
        }

        context.setFillColor(SaverPalette.background.cgColor)
        context.fill(bounds)

        let denBottom = floor - Self.denSunk
        if signOn {
            let board = Self.signBoard.offsetBy(dx: 0, dy: denBottom)
            for (grow, alpha) in [(CGFloat(16), CGFloat(0.035)), (9, 0.05), (3, 0.07)] {
                let halo = board.insetBy(dx: -grow, dy: -grow)
                block(halo.minX, halo.minY, halo.width, halo.height, Tint.neon, alpha: alpha)
            }
        }

        sprite("sea-fan", left: 846 - CGFloat(images["sea-fan"]?.width ?? 0) * px / 2, bottom: floor - px, scale: px, alpha: 0.5)
        sprite(signOn ? "den" : "den_off", left: 0, bottom: denBottom, scale: Self.denScale)

        // Sea floor: a solid row of sand, a checkered row under it, and a few pebbles.
        block(0, floor - px, DenScene.size.width, px, Tint.sand)
        for column in 0..<Int(DenScene.size.width / px) {
            let x = CGFloat(column) * px
            if column % 2 == 0 { block(x, floor - 2 * px, px, px, Tint.sandDark) }
            if column % 5 == 2 { block(x, floor - 3 * px, px, px, Tint.sandDark, alpha: 0.6) }
            if column % 37 == 11 || column % 53 == 29 { block(x, floor - px, 2 * px, px, Tint.pebble) }
        }
        return context.makeImage()
    }
}
