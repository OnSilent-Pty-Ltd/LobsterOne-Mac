#!/usr/bin/env swift
// Draws the app icon (the black claw logo on a white rounded tile) and writes every
// size the asset catalog needs.
//
//   swift scripts/generate-app-icon.swift [background-hex] [output-dir]
//
// Defaults write straight into the Xcode asset catalog.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let args = CommandLine.arguments
let backgroundHex = args.count > 1 ? args[1] : "FFFFFF"
let outDir = args.count > 2
    ? URL(fileURLWithPath: args[2])
    : root.appendingPathComponent("LobsterOne/LobsterOne/Assets.xcassets/AppIcon.appiconset")

// installer-assets/claw.png is the logo's claw path rendered black on transparent at 1024px
// (same path as components/brand/logo.tsx in the web app).
guard let claw = NSImage(contentsOf: root.appendingPathComponent("installer-assets/claw.png"))?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("installer-assets/claw.png not found; run from the repo root")
}

func color(_ hex: String) -> CGColor {
    let v = UInt32(hex, radix: 16) ?? 0
    return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func context(_ side: Int) -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Apple's macOS icon grid: an 824pt tile centred on a 1024pt canvas, with a soft shadow.
func master() -> CGImage {
    let ctx = context(1024)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(color(backgroundHex))
    ctx.fillPath()
    ctx.restoreGState()

    // The claw is vector art rendered large, so scale it smoothly.
    let box: CGFloat = 540
    let scale = min(box / CGFloat(claw.width), box / CGFloat(claw.height))
    let size = CGSize(width: CGFloat(claw.width) * scale, height: CGFloat(claw.height) * scale)
    ctx.addPath(shape)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(claw, in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                              width: size.width, height: size.height))
    return ctx.makeImage()!
}

let full = master()
// File names are the ones Contents.json already lists.
let outputs = [(16, "lobsterone-icon 9.png"), (32, "lobsterone-icon 8.png"), (32, "lobsterone-icon 7.png"),
               (64, "lobsterone-icon 6.png"), (128, "lobsterone-icon 5.png"), (256, "lobsterone-icon 4.png"),
               (256, "lobsterone-icon 3.png"), (512, "lobsterone-icon 2.png"), (512, "lobsterone-icon 1.png"),
               (1024, "lobsterone-icon.png")]
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (side, name) in outputs {
    let ctx = context(side)
    ctx.interpolationQuality = .high
    ctx.draw(full, in: CGRect(x: 0, y: 0, width: side, height: side))
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent(name))
}
print("Wrote \(outputs.count) icons to \(outDir.path)")
