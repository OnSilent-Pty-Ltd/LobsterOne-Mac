import AppKit
import SwiftUI

/// Vector marks for the Horizon look, kept as the SVG path data the web app and the design
/// boards use, so all platforms draw the same shapes.
enum HorizonGlyphs {
    /// The LobsterOne claw (40 x 40), from the web app's `components/brand/logo.tsx`.
    static let claw = "M5.3 34.26 C4.62 33.41 4.09 32.43 3.85 31.37 C1.6 21.19 5.93 7.9 17.7 3 C23.87 0.35 33.09 2.45 36 5.68 C36.75 6.51 36.93 7.71 36.45 8.72 C35.98 9.74 34.95 10.37 33.83 10.33 C28.15 10.14 21.91 14.06 21.73 17.67 C21.73 18.24 22.04 18.76 22.53 19.03 C23.02 19.3 23.62 19.29 24.1 18.99 C27.17 17.07 30.29 18.12 33.87 18.63 C34.66 18.74 35.35 19.21 35.75 19.89 C36.15 20.58 36.2 21.42 35.91 22.15 C32.23 31.25 20.49 38.23 10.05 38.2 C9 38.2 8.02 37.67 7.37 36.84 L5.3 34.26 Z"

    // Interface glyphs (24 x 24, plain line).
    static let openExternal = "M10 5H6a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-4M13 5h6v6M19 5l-8 8"
    static let refresh = "M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4v4h-4"
    static let sliders = "M4 7h10M18 7h2M4 17h2M10 17h10M18 7a2 2 0 1 1-4 0a2 2 0 1 1 4 0M10 17a2 2 0 1 1-4 0a2 2 0 1 1 4 0"
    static let more = "M5.8 12a0.8 0.8 0 1 1-1.6 0a0.8 0.8 0 1 1 1.6 0M12.8 12a0.8 0.8 0 1 1-1.6 0a0.8 0.8 0 1 1 1.6 0M19.8 12a0.8 0.8 0 1 1-1.6 0a0.8 0.8 0 1 1 1.6 0"
    static let warning = "M12 4l9 15.5H3L12 4ZM12 10v4.5M12 17v.5"
    static let check = "M5 12.5l4.5 4.5L19 7.5"
    static let plus = "M12 5v14M5 12h14"
    static let people = "M12.2 8a3.2 3.2 0 1 1-6.4 0a3.2 3.2 0 1 1 6.4 0M3 19.5a6 6 0 0 1 12 0M19.3 9.2a2.4 2.4 0 1 1-4.8 0a2.4 2.4 0 1 1 4.8 0M17.2 14.6a4.6 4.6 0 0 1 3.8 4.9"

    /// Template image of a path, stroked (line glyphs) or filled (the claw), so AppKit can tint it.
    static func templateImage(_ data: String, viewBox: CGFloat, size: CGFloat, lineWidth: CGFloat? = nil,
                              description: String? = nil) -> NSImage {
        let image = image(data, viewBox: viewBox, size: size, lineWidth: lineWidth, color: { .black })
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Image of a path in a colour picked at draw time, so it can follow the appearance.
    static func image(_ data: String, viewBox: CGFloat, size: CGFloat, lineWidth: CGFloat? = nil,
                      color: @escaping () -> NSColor) -> NSImage {
        let path = SVGPath.cgPath(data)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / viewBox
            context.scaleBy(x: scale, y: scale)
            context.addPath(path)
            color().set()
            if let lineWidth {
                context.setLineWidth(lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
            } else {
                context.fillPath()
            }
            return true
        }
    }
}

/// A path from SVG data, scaled from its view box to the frame it is given.
struct SVGShape: Shape {
    let data: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return Path(SVGPath.cgPath(data).copy(using: &transform) ?? SVGPath.cgPath(data))
    }
}

/// A plain line glyph from the interface set, in the current foreground style.
struct LineGlyph: View {
    let data: String
    var size: CGFloat = 17
    var lineWidth: CGFloat = 1.8

    var body: some View {
        SVGShape(data: data)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The claw mark, filled.
struct ClawMark: View {
    var size: CGFloat = 26
    var color: Color = PopoverPalette.logo

    var body: some View {
        SVGShape(data: HorizonGlyphs.claw, viewBox: 40)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// App icons in the "line and accent" style: outlines in the text colour (stroke 1.6, round
/// joins), one part in Lobster. Geometry from the Horizon icon board (24 x 24).
struct AccentGlyph: View {
    struct Geometry {
        var outline: String
        var accentFill: String? = nil
        var accentLine: String? = nil
    }

    static let health = Geometry(
        outline: "M12 20.5s-8-4.8-8-10.5a4.5 4.5 0 0 1 8-2.8 4.5 4.5 0 0 1 8 2.8c0 5.7-8 10.5-8 10.5Z",
        accentLine: "M7 12h2.5l1.5-2.5 2 4.5 1.5-2H17")

    let shape: Geometry
    var size: CGFloat = 20
    var outline: Color = PopoverPalette.text
    var accent: Color = PopoverPalette.brand

    var body: some View {
        let line = 1.6 * size / 24
        ZStack {
            SVGShape(data: shape.outline)
                .stroke(outline, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            if let fill = shape.accentFill {
                SVGShape(data: fill).fill(accent)
            }
            if let detail = shape.accentLine {
                SVGShape(data: detail)
                    .stroke(accent, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A small SVG path-data parser: M L H V C S Q T A Z, absolute and relative. Arcs become cubic
/// curves. Enough for the brand marks and icon set; malformed data yields what parsed so far.
enum SVGPath {
    private static var cache: [String: CGPath] = [:]
    private static let lock = NSLock()

    static func cgPath(_ data: String) -> CGPath {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[data] { return cached }
        let path = parse(data)
        cache[data] = path
        return path
    }

    private static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(Array(data.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while let next = scanner.nextCommand(previous: command) {
            command = next
            let relative = command >= 97 // lowercase
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // further pairs are lines
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p); current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2; current = p
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return path }
                let c1 = "cCsS".utf8.contains(lastCommand) ? reflect(lastControl, about: current) : current
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2; current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                lastControl = c; current = p
            case UInt8(ascii: "t"):
                guard let p = point() else { return path }
                let c = "qQtT".utf8.contains(lastCommand) ? reflect(lastControl, about: current) : current
                path.addQuadCurve(to: p, control: c)
                lastControl = c; current = p
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    private static func reflect(_ point: CGPoint?, about center: CGPoint) -> CGPoint {
        guard let point else { return center }
        return CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// SVG endpoint arc to cubic Béziers (SVG 1.1 implementation notes, F.6.5).
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func onEllipse(_ t: CGFloat) -> (CGPoint, CGPoint) {
            let ex = rx * cos(t), ey = ry * sin(t)
            let point = CGPoint(x: cx + cosPhi * ex - sinPhi * ey, y: cy + sinPhi * ex + cosPhi * ey)
            let tx = -rx * sin(t), ty = ry * cos(t)
            let tangent = CGPoint(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty)
            return (point, tangent)
        }
        var t = theta1
        for _ in 0..<segments {
            let (a, ta) = onEllipse(t)
            let (b, tb) = onEllipse(t + step)
            path.addCurve(to: b,
                          control1: CGPoint(x: a.x + k * ta.x, y: a.y + k * ta.y),
                          control2: CGPoint(x: b.x - k * tb.x, y: b.y - k * tb.y))
            t += step
        }
    }

    /// Reads commands and numbers from path data, allowing the compact forms ("1-1", ".5.5").
    private struct Tokens {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || (9...13).contains(bytes[index]) {
                index += 1
            }
        }

        /// The next explicit command letter, or the previous one repeated when numbers follow.
        mutating func nextCommand(previous: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (65...90).contains(byte) || (97...122).contains(byte) {
                index += 1
                return byte
            }
            let z = previous | 0x20
            return previous == 0 || z == UInt8(ascii: "z") ? nil : previous
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
            defer { index += 1 }
            return bytes[index] == 49
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            var seenDot = false, seenDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) { seenDigit = true; index += 1 }
                else if byte == 46 && !seenDot { seenDot = true; index += 1 }
                else if (byte == 101 || byte == 69) && seenDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
                } else { break }
            }
            guard seenDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii),
                  let value = Double(text) else { index = begin; return nil }
            return CGFloat(value)
        }
    }
}
