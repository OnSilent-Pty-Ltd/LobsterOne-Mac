import Testing
import AppKit
@testable import LobsterOne

/// The colour at the top of the ring (where the arc starts) when drawn under an appearance.
@MainActor private func arcColor(percent: Double, appearance name: NSAppearance.Name) throws -> NSColor {
    let image = StatusBarController.ringGlyph(percent: percent)
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
    }
    return try #require(rep.colorAt(x: 18, y: 4))
}

/// The red ring follows the menu bar it is drawn on without anyone rebuilding the image:
/// the same image gives the light red on a light bar and the dark-mode red on a dark one.
@MainActor @Test func criticalRingPicksItsColourAtDrawTime() throws {
    let light = try arcColor(percent: 90, appearance: .aqua)
    let dark = try arcColor(percent: 90, appearance: .darkAqua)
    #expect(light.redComponent > 0.5 && light.greenComponent < 0.3)   // #A32A1D
    #expect(dark.redComponent > 0.9 && dark.greenComponent > 0.5)     // #FF9A8C
    #expect(!StatusBarController.ringGlyph(percent: 90).isTemplate)
    #expect(StatusBarController.ringGlyph(percent: 40).isTemplate)
}
