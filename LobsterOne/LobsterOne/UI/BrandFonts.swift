import AppKit
import CoreText
import Foundation
import SwiftUI

/// The brand typefaces, bundled under Resources/Fonts (SIL OFL 1.1, licenses alongside):
/// Schibsted Grotesk for all text and numbers, JetBrains Mono only for real code (key prefixes).
///
/// Schibsted Grotesk ships as two variable WOFF2 subsets (latin and latin-ext), which CoreText
/// reads directly. Both subsets carry the same PostScript name, so only latin is registered and
/// latin-ext is attached as the first fallback in each font's cascade list. Weights are set on
/// the `wght` axis (400 to 900).
@MainActor
enum BrandFonts {
    static let sansFamily = "Schibsted Grotesk"
    static let monoFamily = "JetBrains Mono"

    private static let sansFile = ("SchibstedGrotesk-latin", "woff2")
    private static let sansExtFile = ("SchibstedGrotesk-latin-ext", "woff2")
    private static let monoFile = ("JetBrainsMono", "ttf")
    /// The OpenType `wght` axis tag.
    private static let weightAxis = NSNumber(value: 0x7767_6874)

    /// Registers the bundled fonts for this process, once. If a file is missing or rejected,
    /// it is logged and the system font stands in for that family.
    static let registered: Bool = {
        var ok = true
        for (name, ext) in [sansFile, monoFile] {
            guard let url = fontURL(name, ext) else {
                DebugLog.shared.log("BrandFonts: \(name).\(ext) missing from bundle, using system font")
                ok = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let nsError = error?.takeRetainedValue() as Error? as NSError?
                if nsError?.code != CTFontManagerError.alreadyRegistered.rawValue {
                    DebugLog.shared.log("BrandFonts: failed to register \(name): \(nsError?.localizedDescription ?? "unknown error")")
                    ok = false
                }
            }
        }
        return ok
    }()

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let font = sansFont(size, weight: axisValue(weight)) else {
            return .system(size: size, weight: weight)
        }
        return Font(font)
    }

    /// The same face for AppKit (menu bar title, block screen). Tabular figures when `tabular`.
    static func nsSans(_ size: CGFloat, weight: NSFont.Weight = .regular, tabular: Bool = false) -> NSFont {
        guard let font = sansFont(size, weight: axisValue(weight), tabular: tabular) else {
            return tabular ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        }
        return font as NSFont
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registered
        return .custom(monoFamily, size: size).weight(weight)
    }

    // MARK: - Schibsted Grotesk

    private static let sansDescriptor: CTFontDescriptor? = descriptor(sansFile)
    private static let sansExtDescriptor: CTFontDescriptor? = descriptor(sansExtFile)
    private static var cache: [String: CTFont] = [:]

    private static func descriptor(_ file: (String, String)) -> CTFontDescriptor? {
        guard let url = fontURL(file.0, file.1),
              let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return nil }
        // The first descriptor is the default instance; the named instances follow it.
        return list.first
    }

    private static func sansFont(_ size: CGFloat, weight: CGFloat, tabular: Bool = false) -> CTFont? {
        guard registered, let base = sansDescriptor else { return nil }
        let key = "\(size)/\(weight)/\(tabular)"
        if let cached = cache[key] { return cached }

        let variation = [weightAxis: weight] as CFDictionary
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: variation]
        if let ext = sansExtDescriptor {
            attributes[kCTFontCascadeListAttribute] = [
                CTFontDescriptorCreateCopyWithAttributes(ext, [kCTFontVariationAttribute: variation] as CFDictionary),
            ]
        }
        if tabular {
            attributes[kCTFontFeatureSettingsAttribute] = [
                [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1],
            ]
        }
        let font = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary), size, nil)
        cache[key] = font
        return font
    }

    /// Maps a SwiftUI weight onto the font's `wght` axis. The font starts at 400, so lighter
    /// weights resolve to regular.
    static func axisValue(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    static func axisValue(_ weight: NSFont.Weight) -> CGFloat {
        switch weight {
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    /// SPM copies Resources/Fonts into its resource bundle; the Xcode project's synchronized
    /// folder flattens resources into Contents/Resources.
    private static func fontURL(_ name: String, _ ext: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fonts")
        #else
        return Bundle.main.url(forResource: name, withExtension: ext)
        #endif
    }
}
