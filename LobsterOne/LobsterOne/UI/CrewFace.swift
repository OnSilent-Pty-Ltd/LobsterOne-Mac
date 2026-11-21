import AppKit
import ImageIO
import SwiftUI

/// The crew's portraits, from Resources/Crew.
enum CrewPortrait {
    private static var cache: [String: CGImage] = [:]

    /// The portrait resampled to exactly `pixels` across. Letting the view shrink the full
    /// picture at draw time thins the ink lines to grey; one good resample keeps them dark.
    static func image(_ face: String, pixels: Int) -> CGImage? {
        let key = "\(face)@\(pixels)"
        if let image = cache[key] { return image }
        guard let url = url(face), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        cache[key] = image
        return image
    }

    static func url(_ face: String) -> URL? {
        // The name comes from a charter file, so only plain lowercase names are looked up.
        guard !face.isEmpty, face.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return nil }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "crew-\(face)", withExtension: "jpg", subdirectory: "Crew")
        #else
        // The Xcode project flattens resources into Contents/Resources.
        return Bundle.main.url(forResource: "crew-\(face)", withExtension: "jpg")
        #endif
    }
}

/// A crew member's round portrait; an initial on Blush when there is no portrait to show.
struct CrewFace: View {
    let face: String?
    let name: String
    var size: CGFloat = 36
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let face, let image = CrewPortrait.image(face, pixels: Int((size * displayScale).rounded())) {
            Image(decorative: image, scale: displayScale)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(BrandFonts.sans(size * 0.42, weight: .semibold))
                .foregroundStyle(PopoverPalette.brandText)
                .frame(width: size, height: size)
                .background(PopoverPalette.blush, in: Circle())
                .accessibilityHidden(true)
        }
    }
}

/// The crew's mark in the menu bar: one orange dot when a member needs attention. Faces were
/// tried here and did not read well at this size, so the dot stands alone; who it is about is
/// on the Team page, which opening the popover lands on.
@MainActor
enum CrewMenuBarGlyph {
    static let dotSize: CGFloat = 7

    static func dot(count: Int) -> NSImage {
        let size = dotSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(hex: 0xE0542A).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.accessibilityDescription = count == 1 ? "A crew member needs your attention" : "\(count) crew members need your attention"
        return image
    }
}
