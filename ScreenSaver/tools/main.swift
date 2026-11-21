import AppKit

// Converts the generated sheets and the web game's plants into the saver's sprites.
// usage: convert <source dir> <output dir>
// The source dir holds garry-sheet.png (4 x 4 cells), shell-sheet.png (4 x 2 cells),
// kelp.png and sea-fan.png. See ../Sprites/README.md.

let sourceDir = CommandLine.arguments[1], out = CommandLine.arguments[2]
let ink = Px(r: 23, g: 8, b: 11, a: 255)
let pixel = 1.57   // scene units per sprite pixel, as in DenView

func isBackdrop(_ q: Px) -> Bool { q.b > 120 && q.r > 150 && q.g < 85 }

func cropRect(_ s: Img, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Img {
    var o = Img(w, h)
    for y in 0..<h { for x in 0..<w { o[x, y] = s[x + x0, y + y0] } }
    return o
}

/// Block size and offset along one axis, by comb-filtering the edge profile.
func detect(_ s: Img, horizontal: Bool, range: ClosedRange<Double>) -> (b: Double, off: Double, score: Double) {
    let n = horizontal ? s.w : s.h
    var prof = [Double](repeating: 0, count: n)
    func d(_ a: Px, _ b: Px) -> Double {
        abs(Double(a.r) - Double(b.r)) + abs(Double(a.g) - Double(b.g)) + abs(Double(a.b) - Double(b.b)) + abs(Double(a.a) - Double(b.a))
    }
    for y in 0..<s.h { for x in 0..<s.w {
        if horizontal { if x > 0 { prof[x] += d(s[x, y], s[x - 1, y]) } } else if y > 0 { prof[y] += d(s[x, y], s[x, y - 1]) }
    } }
    let mean = max(prof.reduce(0, +) / Double(n), 1e-9)
    var best = (b: 0.0, off: 0.0, score: 0.0), b = range.lowerBound
    while b <= range.upperBound {
        var o = 0.0
        while o < b {
            var sum = 0.0, cnt = 0.0, x = o
            while x < Double(n) - 1 { sum += prof[Int(x.rounded())]; cnt += 1; x += b }
            if sum / cnt / mean > best.score { best = (b, o, sum / cnt / mean) }
            o += 0.25
        }
        b += 0.02
    }
    return best
}

// MARK: - Garry

var sheet = load("\(sourceDir)/garry-sheet.png")

// The generator drew black rules between cells. A column or row that is dark nearly all the
// way across is a rule, not a character.
func isDark(_ q: Px) -> Bool { Int(q.r) + Int(q.g) + Int(q.b) < 110 }
var ruleColumns = Set<Int>(), ruleRows = Set<Int>()
for x in 0..<sheet.w { var dark = 0; for y in 0..<sheet.h where isDark(sheet[x, y]) { dark += 1 }; if dark * 10 > sheet.h * 8 { ruleColumns.insert(x) } }
for y in 0..<sheet.h { var dark = 0; for x in 0..<sheet.w where isDark(sheet[x, y]) { dark += 1 }; if dark * 10 > sheet.w * 8 { ruleRows.insert(y) } }
print("cell rules removed: \(ruleColumns.count) columns, \(ruleRows.count) rows")

var keyed = sheet
for y in 0..<sheet.h { for x in 0..<sheet.w {
    if isBackdrop(sheet[x, y]) || ruleColumns.contains(x) || ruleRows.contains(y) { keyed[x, y] = .clear }
} }
// It also put a pale halo round each figure. Drop near-white pixels close to the backdrop;
// the cap badge and eye glints are further inside.
let beforeHalo = keyed
for y in 0..<keyed.h { for x in 0..<keyed.w {
    let q = beforeHalo[x, y]
    guard q.opaque, q.r > 195, q.g > 195, q.b > 195 else { continue }
    var nearEdge = false
    for dy in stride(from: -4, through: 4, by: 2) { for dx in stride(from: -4, through: 4, by: 2) where !beforeHalo[x + dx, y + dy].opaque { nearEdge = true } }
    if nearEdge { keyed[x, y] = .clear }
} }

let names = ["idle", "blink", "sleep", "cheer", "walk-1", "walk-2", "walk-3", "walk-4",
             "carry-1", "carry-2", "carry-3", "carry-4", "reach", "grip", "push", "wave"]
let cols = 4, rows = 4
let cellW = keyed.w / cols, cellH = keyed.h / rows
var frames: [Img] = []
for r in 0..<rows { for c in 0..<cols {
    var cell = cropRect(keyed, c * cellW, r * cellH, cellW, cellH)
    if names[r * cols + c] == "sleep" {
        // A loose "Z" floats beside him; the saver draws its own.
        for y in 0..<(cellH * 24 / 100) { for x in (cellW * 62 / 100)..<cellW { cell[x, y] = .clear } }
    }
    let gx = detect(cell, horizontal: true, range: 8.4...11.0), gy = detect(cell, horizontal: false, range: 8.4...11.0)
    print(String(format: "%@  x: B=%.2f score=%.2f   y: B=%.2f score=%.2f", names[r * cols + c].padding(toLength: 8, withPad: " ", startingAt: 0), gx.b, gx.score, gy.b, gy.score))
    frames.append(sampleGrid(cell, bx: gx.b, ox: gx.off, by: gy.b, oy: gy.off))
} }
quantize(&frames, colours: 28)
frames = frames.map { despeckle($0) }.map { crop($0, trimmedBounds($0)) }

// Common canvas: feet on one baseline, cap centred on one column.
func capX(_ f: Img) -> Double {
    var sx = 0.0, n = 0.0
    for y in 0..<f.h { for x in 0..<f.w { let q = f[x, y]; if q.opaque, Int(q.b) > Int(q.r) + 30 { sx += Double(x); n += 1 } } }
    return n > 0 ? sx / n : Double(f.w) / 2
}
let W = 80, H = 66, anchorX = 38
var placed: [Img] = []
for f in frames {
    var o = Img(W, H)
    let dx = anchorX - Int(capX(f).rounded()), dy = H - 2 - f.h
    for y in 0..<f.h { for x in 0..<f.w where f[x, y].opaque { o[x + dx, y + dy] = f[x, y] } }
    placed.append(o)
}
for i in placed.indices {
    var capBottom = -1
    for y in 0..<H { for x in 0..<W { let q = placed[i][x, y]; if q.opaque, Int(q.b) > Int(q.r) + 30 { capBottom = max(capBottom, y) } } }
    let snap = placed[i]
    for y in min(capBottom + 12, H)..<H { for x in 0..<W {
        let q = snap[x, y]
        guard q.opaque, q.r > 200, q.g > 200, q.b > 200 else { continue }
        var votes: [Px: Int] = [:]
        for dy in -1...1 { for dx in -1...1 { let nb = snap[x + dx, y + dy]; if nb.opaque, !(nb.r > 200 && nb.g > 200 && nb.b > 200) { votes[nb, default: 0] += 1 } } }
        func rank(_ e: (key: Px, value: Int)) -> (Int, UInt8, UInt8, UInt8) { (e.value, e.key.r, e.key.g, e.key.b) }
        placed[i][x, y] = votes.max { rank($0) < rank($1) }?.key ?? .clear
    } }
}
print("tallest frame: \(frames.map(\.h).max()!) of \(H), widest: \(frames.map(\.w).max()!) of \(W)")

// Frames with a shell painted in: remove it so the saver can draw whichever shell he picked
// up, and note where it was. The constants in DenView come from this output.
var holds: [(String, Double, Double)] = []
for (i, name) in names.enumerated() where name.hasPrefix("carry") || name == "grip" || name == "push" {
    var f = placed[i]
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in (H * 35 / 100)..<H { for x in (anchorX - 10)..<W {
        let q = f[x, y]
        let cream = q.r > 220 && q.g > 180 && q.b > 125 && q.b < 220
        let tan = !name.hasPrefix("carry") && y > H * 70 / 100 && q.r > 200 && q.g > 140 && q.b > 80 && q.b < 220
        if q.opaque, cream || tan { f[x, y] = .clear; sx += Double(x); sy += Double(y); n += 1 }
    } }
    // Outline pixels left with no body next to them belonged to the shell.
    for _ in 0..<3 {
        let snap = f
        for y in (H * 30 / 100)..<H { for x in (anchorX - 12)..<W {
            let q = snap[x, y]
            guard q.opaque, isDark(q) else { continue }
            var body = false
            for dy in -1...1 { for dx in -1...1 { let nb = snap[x + dx, y + dy]; if nb.opaque, !isDark(nb) { body = true } } }
            if !body { f[x, y] = .clear }
        } }
    }
    placed[i] = f
    holds.append((name, sx / max(n, 1) * 2, sy / max(n, 1) * 2))
}

var garry = placed.map(scale2x)

// The cap's numeral does not survive at this size, so stamp a clean one on the badge: the
// patch of near-white pixels in the cap, above the eyes.
let navy = Px(r: 34, g: 52, b: 92, a: 255), white = Px(r: 250, g: 248, b: 240, a: 255)
let one = [".#.", "##.", ".#.", ".#.", "###"]
func stamped(_ source: Img, _ name: String) -> Img {
    var img = source
    // The cap is the blue band; the badge sits within its rows and columns.
    var capTop = Int.max, capBottom = -1, capLeft = Int.max, capRight = -1
    for y in 0..<img.h { for x in 0..<img.w {
        let q = img[x, y]
        if q.opaque, Int(q.b) > Int(q.r) + 30 { capTop = min(capTop, y); capBottom = max(capBottom, y); capLeft = min(capLeft, x); capRight = max(capRight, x) }
    } }
    var xs: [Int] = [], ys: [Int] = []
    if capBottom >= 0 {
        for y in capTop...capBottom { for x in capLeft...capRight {
            let q = img[x, y]
            if q.opaque, q.r > 215, q.g > 215, q.b > 185 { xs.append(x); ys.append(y) }
        } }
    }
    guard !xs.isEmpty else { print("no badge found in \(name)"); return img }
    let cx = xs.sorted()[xs.count / 2], cy = ys.sorted()[ys.count / 2]
    for y in (cy - 4)...(cy + 4) { for x in (cx - 3)...(cx + 3) { img[x, y] = white } }
    for (r, row) in one.enumerated() { for (c, ch) in row.enumerated() where ch == "#" { img[cx - 1 + c, cy - 2 + r] = navy } }
    return img
}
func mirrored(_ s: Img) -> Img {
    var o = Img(s.w, s.h)
    for y in 0..<s.h { for x in 0..<s.w { o[s.w - 1 - x, y] = s[x, y] } }
    return o
}
// Frames he uses facing left get their own mirrored copy, stamped after mirroring so the
// numeral still reads the right way round.
for (i, name) in names.enumerated() where name.hasPrefix("carry") || name == "push" {
    save(stamped(mirrored(garry[i]), "\(name)-left"), "\(out)/garry-\(name)-left.png")
}
garry = garry.enumerated().map { stamped($0.element, names[$0.offset]) }
for (i, f) in garry.enumerated() { save(f, "\(out)/garry-\(names[i]).png") }
print("garry canvas \(garry[0].w)x\(garry[0].h) anchorX \(anchorX * 2)")
for h in holds { print(String(format: "hold %@: x=%.1f y=%.1f", h.0, h.1, h.2)) }

// MARK: - Shells: 4 by 2 cells, each on its own grid.

var shellSheet = load("\(sourceDir)/shell-sheet.png")
for i in shellSheet.p.indices where isBackdrop(shellSheet.p[i]) { shellSheet.p[i] = .clear }
var shells: [Img] = []
for r in 0..<2 { for c in 0..<4 {
    let cell = cropRect(shellSheet, c * shellSheet.w / 4, r * shellSheet.h / 2, shellSheet.w / 4, shellSheet.h / 2)
    let gx = detect(cell, horizontal: true, range: 6...16), gy = detect(cell, horizontal: false, range: 6...16)
    shells.append(sampleGrid(cell, bx: gx.b, ox: gx.off, by: gy.b, oy: gy.off))
} }
quantize(&shells, colours: 36)
shells = shells.map { despeckle($0) }.map { crop($0, trimmedBounds($0)) }
for (i, s) in shells.enumerated() { save(s, "\(out)/shell-\(i + 1).png") }

// MARK: - Plants from the web game: resample to the same pixel size, limit the palette, outline.

func plant(_ name: String, drawnScale: Double, colours: Int, coverage: Double) -> Img {
    var imgs = [areaDown(load("\(sourceDir)/\(name).png"), factor: pixel / drawnScale, coverage: coverage)]
    quantize(&imgs, colours: colours)
    return outlined(despeckle(imgs[0]), ink)
}
let kelp = plant("kelp", drawnScale: 0.5, colours: 9, coverage: 0.5)
let seaFan = plant("sea-fan", drawnScale: 0.62, colours: 6, coverage: 0.3)
save(kelp, "\(out)/kelp.png")
save(seaFan, "\(out)/sea-fan.png")

// MARK: - Web game exports (Robocog---Frontend/web/public/game)
//
// The game draws the lobster into a fixed 75 x 71 box and a shell into 26 x 22, 1:1 on its
// canvas. Neither is a whole multiple of the art, so these are resized here with a box filter
// instead of letting the canvas pick pixels unevenly.

let webDir = "\(out)/web"
try? FileManager.default.createDirectory(atPath: webDir, withIntermediateDirectories: true)
let webNames = ["idle", "walk-1", "walk-2", "walk-3", "walk-4"]
let webFrames = webNames.map { garry[names.firstIndex(of: $0)!] }
// One crop for every frame so he does not jitter, padded up to the box's proportions.
var union = (x0: Int.max, y0: Int.max, x1: -1, y1: -1)
for f in webFrames { let b = trimmedBounds(f); union = (min(union.x0, b.x0), min(union.y0, b.y0), max(union.x1, b.x1), max(union.y1, b.y1)) }
let boxW = 75, boxH = 71
var cropW = union.x1 - union.x0 + 1, cropH = union.y1 - union.y0 + 1
if cropW * boxH < cropH * boxW { let want = (cropH * boxW + boxH - 1) / boxH; union.x0 -= (want - cropW) / 2; cropW = want }
else { let want = (cropW * boxH + boxW - 1) / boxW; union.y0 -= want - cropH; cropH = want }   // extra rows go above; feet stay on the bottom edge
func webFrame(_ f: Img) -> Img { resampleSoft(cropRect(f, union.x0, union.y0, cropW, cropH), to: boxW, boxH) }
for (name, f) in zip(webNames, webFrames) {
    save(webFrame(f), "\(webDir)/garry-\(name).png")
    // Facing left: mirror the crop, then stamp, so the numeral is not reversed.
    let i = names.firstIndex(of: name)!
    let unstamped = scale2x(placed[i])
    let left = stamped(mirrored(cropRect(unstamped, union.x0, union.y0, cropW, cropH)), "\(name) (web, left)")
    save(resampleSoft(left, to: boxW, boxH), "\(webDir)/garry-\(name)-left.png")
}
print("web lobster crop \(cropW)x\(cropH) -> \(boxW)x\(boxH)")
// Shells keep their own proportions inside the 26 x 22 box, resting on its bottom edge.
for (i, s) in shells.enumerated() {
    let fit = min(26.0 / Double(s.w), 22.0 / Double(s.h))
    let w = max(1, Int((Double(s.w) * fit).rounded())), h = max(1, Int((Double(s.h) * fit).rounded()))
    let small = resampleSoft(s, to: w, h)
    var boxed = Img(26, 22)
    for y in 0..<h { for x in 0..<w { boxed[x + (26 - w) / 2, y + 22 - h] = small[x, y] } }
    save(boxed, "\(webDir)/shell-\(i + 1).png")
}

// MARK: - Check sheet: every Garry frame with a shell in the hold spot, then shells and plants.

let k = 3, bg = Px(r: 0x1F, g: 0x1A, b: 0x17, a: 255)
var check = Img(garry[0].w * 8 * k, (garry[0].h * 2 + 110) * k)
for i in check.p.indices { check.p[i] = bg }
func blit(_ s: Img, _ ox: Int, _ oy: Int) {
    for y in 0..<s.h { for x in 0..<s.w where s[x, y].opaque { for yy in 0..<k { for xx in 0..<k { check[(ox + x) * k + xx, (oy + y) * k + yy] = s[x, y] } } } }
}
for (i, f) in garry.enumerated() {
    let ox = (i % 8) * f.w, oy = (i / 8) * f.h
    blit(f, ox, oy)
    if let h = holds.first(where: { $0.0 == names[i] }) { let s = shells[(i * 3) % 8]; blit(s, ox + Int(h.1) - s.w / 2, oy + Int(h.2) - s.h / 2) }
}
for (i, s) in shells.enumerated() { blit(s, 20 + i * 52, garry[0].h * 2 + 40) }
blit(kelp, 480, garry[0].h * 2 + 4)
blit(seaFan, 590, garry[0].h * 2 + 26)
save(check, "\(out)/check.png")
