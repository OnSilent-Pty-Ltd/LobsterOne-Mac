import AppKit

struct Px: Hashable { var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    static let clear = Px(r: 0, g: 0, b: 0, a: 0)
    var opaque: Bool { a > 0 } }

struct Img { var w: Int, h: Int, p: [Px]
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; p = Array(repeating: .clear, count: w * h) }
    subscript(x: Int, y: Int) -> Px {
        get { (x < 0 || y < 0 || x >= w || y >= h) ? .clear : p[y * w + x] }
        set { if x >= 0, y >= 0, x < w, y < h { p[y * w + x] = newValue } } }
}

func load(_ path: String) -> Img {
    let cg = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!.cgImage!
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var img = Img(w, h)
    for i in 0..<(w * h) { let a = Double(buf[i * 4 + 3])
        if a > 0 { func un(_ v: UInt8) -> UInt8 { UInt8(min(255, Double(v) * 255 / a)) }
            img.p[i] = Px(r: un(buf[i * 4]), g: un(buf[i * 4 + 1]), b: un(buf[i * 4 + 2]), a: buf[i * 4 + 3]) } }
    return img
}

func save(_ img: Img, _ path: String) {
    var buf = [UInt8](repeating: 0, count: img.w * img.h * 4)
    for i in 0..<(img.w * img.h) { let q = img.p[i]; let a = Double(q.a) / 255
        buf[i * 4] = UInt8(Double(q.r) * a); buf[i * 4 + 1] = UInt8(Double(q.g) * a); buf[i * 4 + 2] = UInt8(Double(q.b) * a); buf[i * 4 + 3] = q.a }
    let ctx = CGContext(data: &buf, width: img.w, height: img.h, bitsPerComponent: 8, bytesPerRow: img.w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Read one colour per cell of a (possibly non-square, offset) block grid: the most common
/// colour in the middle of the cell, which ignores the blurred block edges.
func sampleGrid(_ s: Img, bx: Double, ox: Double, by: Double, oy: Double) -> Img {
    let x0 = ox - bx * (ox / bx).rounded(.up), y0 = oy - by * (oy / by).rounded(.up)
    let cols = Int(((Double(s.w) - x0) / bx).rounded(.up)), rows = Int(((Double(s.h) - y0) / by).rounded(.up))
    var out = Img(cols, rows)
    for cy in 0..<rows { for cx in 0..<cols {
        let ax = x0 + Double(cx) * bx, ay = y0 + Double(cy) * by
        var votes: [UInt32: (n: Int, r: Int, g: Int, b: Int)] = [:], total = 0, solid = 0
        for y in Int((ay + by * 0.25).rounded())...Int((ay + by * 0.75).rounded()) { for x in Int((ax + bx * 0.25).rounded())...Int((ax + bx * 0.75).rounded()) {
            guard x >= 0, y >= 0, x < s.w, y < s.h else { continue }
            total += 1; let q = s[x, y]; guard q.a > 128 else { continue }
            solid += 1
            let key = UInt32(q.r >> 3) << 10 | UInt32(q.g >> 3) << 5 | UInt32(q.b >> 3)
            var v = votes[key] ?? (0, 0, 0, 0); v.n += 1; v.r += Int(q.r); v.g += Int(q.g); v.b += Int(q.b); votes[key] = v } }
        if total > 0, solid * 2 > total, let v = votes.max(by: { ($0.value.n, $0.key) < ($1.value.n, $1.key) })?.value {
            out[cx, cy] = Px(r: UInt8(v.r / v.n), g: UInt8(v.g / v.n), b: UInt8(v.b / v.n), a: 255) } } }
    return out
}

/// Plain area average, for art that never had a real grid.
func areaDown(_ s: Img, factor f: Double, coverage: Double = 0.5) -> Img {
    let w = Int((Double(s.w) / f).rounded()), h = Int((Double(s.h) / f).rounded())
    var out = Img(w, h)
    for cy in 0..<h { for cx in 0..<w {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0, n = 0.0
        for y in Int(Double(cy) * f)..<max(Int(Double(cy + 1) * f), Int(Double(cy) * f) + 1) { for x in Int(Double(cx) * f)..<max(Int(Double(cx + 1) * f), Int(Double(cx) * f) + 1) {
            guard x < s.w, y < s.h else { continue }
            let q = s[x, y], al = Double(q.a) / 255
            r += Double(q.r) * al; g += Double(q.g) * al; b += Double(q.b) * al; a += al; n += 1 } }
        if n > 0, a / n >= coverage { out[cx, cy] = Px(r: UInt8(r / a), g: UInt8(g / a), b: UInt8(b / a), a: 255) } } }
    return out
}

/// Median cut to `n` colours over every opaque pixel of the given images, then remap them.
func quantize(_ imgs: inout [Img], colours n: Int) {
    var boxes: [[Px]] = [imgs.flatMap { $0.p.filter(\.opaque) }]
    func range(_ b: [Px]) -> (Int, Int) {
        var best = (0, -1)
        for (i, kp) in [\Px.r, \Px.g, \Px.b].enumerated() { let v = b.map { Int($0[keyPath: kp]) }; let d = (v.max() ?? 0) - (v.min() ?? 0); if d > best.1 { best = (i, d) } }
        return best }
    while boxes.count < n {
        guard let idx = boxes.indices.filter({ boxes[$0].count > 1 }).max(by: { range(boxes[$0]).1 * Int(Double(boxes[$0].count).squareRoot()) < range(boxes[$1]).1 * Int(Double(boxes[$1].count).squareRoot()) }), range(boxes[idx]).1 > 0 else { break }
        let ch = range(boxes[idx]).0; let kp = [\Px.r, \Px.g, \Px.b][ch]
        let sorted = boxes[idx].sorted { $0[keyPath: kp] < $1[keyPath: kp] }
        boxes[idx] = Array(sorted[..<(sorted.count / 2)]); boxes.append(Array(sorted[(sorted.count / 2)...])) }
    let palette = boxes.filter { !$0.isEmpty }.map { b -> Px in
        Px(r: UInt8(b.reduce(0) { $0 + Int($1.r) } / b.count), g: UInt8(b.reduce(0) { $0 + Int($1.g) } / b.count), b: UInt8(b.reduce(0) { $0 + Int($1.b) } / b.count), a: 255) }
    for i in imgs.indices { for j in imgs[i].p.indices where imgs[i].p[j].opaque {
        let q = imgs[i].p[j]
        imgs[i].p[j] = palette.min { a, b in
            func d(_ c: Px) -> Int { let dr = Int(c.r) - Int(q.r), dg = Int(c.g) - Int(q.g), db = Int(c.b) - Int(q.b); return 2 * dr * dr + 4 * dg * dg + 3 * db * db }
            return d(a) < d(b) }! } }
}

/// EPX / Scale2x: doubles resolution and rounds off staircase diagonals, staying crisp.
func scale2x(_ s: Img) -> Img {
    var o = Img(s.w * 2, s.h * 2)
    for y in 0..<s.h { for x in 0..<s.w {
        let p = s[x, y], a = s[x, y - 1], b = s[x + 1, y], c = s[x - 1, y], d = s[x, y + 1]
        o[x * 2, y * 2] = (c == a && c != d && a != b) ? a : p
        o[x * 2 + 1, y * 2] = (a == b && a != c && b != d) ? b : p
        o[x * 2, y * 2 + 1] = (d == c && d != b && c != a) ? c : p
        o[x * 2 + 1, y * 2 + 1] = (b == d && b != a && d != c) ? d : p } }
    return o
}

/// One-pixel outline around the silhouette, on a canvas one pixel larger each side.
func outlined(_ s: Img, _ colour: Px) -> Img {
    var o = Img(s.w + 2, s.h + 2)
    for y in 0..<o.h { for x in 0..<o.w {
        let p = s[x - 1, y - 1]
        if p.opaque { o[x, y] = p }
        else if s[x - 2, y - 1].opaque || s[x, y - 1].opaque || s[x - 1, y - 2].opaque || s[x - 1, y].opaque { o[x, y] = colour } } }
    return o
}

/// Drop specks: opaque pixels with no opaque 4-neighbour.
func despeckle(_ s: Img) -> Img {
    var o = s
    for y in 0..<s.h { for x in 0..<s.w where s[x, y].opaque {
        if !(s[x - 1, y].opaque || s[x + 1, y].opaque || s[x, y - 1].opaque || s[x, y + 1].opaque) { o[x, y] = .clear } } }
    return o
}

func trimmedBounds(_ s: Img) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
    var x0 = s.w, y0 = s.h, x1 = -1, y1 = -1
    for y in 0..<s.h { for x in 0..<s.w where s[x, y].opaque { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) } }
    return (x0, y0, x1, y1)
}

func crop(_ s: Img, _ b: (x0: Int, y0: Int, x1: Int, y1: Int)) -> Img {
    var o = Img(b.x1 - b.x0 + 1, b.y1 - b.y0 + 1)
    for y in 0..<o.h { for x in 0..<o.w { o[x, y] = s[x + b.x0, y + b.y0] } }
    return o
}

func ascii(_ s: Img) -> String {
    var keys: [Px: Character] = [:]; let glyphs = Array("#@%&8BWMXZO0QLCJUYoahkbdpqwmzcvunxrjft/|()1{}[]?-_+~<>i!lI;:,^`'. ")
    var out = ""
    for y in 0..<s.h { for x in 0..<s.w { let p = s[x, y]
        if !p.opaque { out.append(" ") } else { if keys[p] == nil { keys[p] = glyphs[keys.count % glyphs.count] }; out.append(keys[p]!) } }; out.append("\n") }
    return out + keys.sorted { String($0.value) < String($1.value) }.map { "\($0.value)=\($0.key.r),\($0.key.g),\($0.key.b)" }.joined(separator: "  ")
}

/// Box-filter resize to an exact size with soft edges, for targets that draw sprites 1:1 at
/// a size that is not a whole multiple of the art (the web game).
func resampleSoft(_ s: Img, to w: Int, _ h: Int) -> Img {
    var o = Img(w, h)
    let fx = Double(s.w) / Double(w), fy = Double(s.h) / Double(h)
    for oy in 0..<h { for ox in 0..<w {
        let x0 = Double(ox) * fx, x1 = Double(ox + 1) * fx, y0 = Double(oy) * fy, y1 = Double(oy + 1) * fy
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0, area = 0.0
        for sy in Int(y0)..<min(Int(y1.rounded(.up)), s.h) { for sx in Int(x0)..<min(Int(x1.rounded(.up)), s.w) {
            let cover = (min(x1, Double(sx + 1)) - max(x0, Double(sx))) * (min(y1, Double(sy + 1)) - max(y0, Double(sy)))
            guard cover > 0 else { continue }
            let q = s[sx, sy], alpha = Double(q.a) / 255 * cover
            r += Double(q.r) * alpha; g += Double(q.g) * alpha; b += Double(q.b) * alpha; a += alpha; area += cover
        } }
        if a > 0, area > 0 { o[ox, oy] = Px(r: UInt8(r / a), g: UInt8(g / a), b: UInt8(b / a), a: UInt8(min(255, a / area * 255))) }
    } }
    return o
}
