import Testing
import AppKit
@testable import LobsterOne

@MainActor @Test func brandFontsRegisterAndResolve() throws {
    #expect(BrandFonts.registered)
    let sans = BrandFonts.nsSans(14)
    #expect(sans.familyName == BrandFonts.sansFamily)
    let mono = try #require(NSFontManager.shared.font(withFamily: BrandFonts.monoFamily, traits: [], weight: 5, size: 12))
    #expect(mono.familyName == BrandFonts.monoFamily)
}

/// The WOFF2 is variable: a weight must land on the `wght` axis of the same family, not a fallback.
@MainActor @Test func brandSansWeightsUseTheVariableAxis() throws {
    let semibold = BrandFonts.nsSans(14, weight: .semibold)
    #expect(semibold.familyName == BrandFonts.sansFamily)
    let variation = try #require(CTFontCopyVariation(semibold as CTFont) as? [NSNumber: NSNumber])
    #expect(variation[NSNumber(value: 0x7767_6874)]?.doubleValue == 600)
    // Heavier weights draw wider glyphs.
    let regularWidth = ("LobsterOne" as NSString).size(withAttributes: [.font: BrandFonts.nsSans(14)]).width
    let boldWidth = ("LobsterOne" as NSString).size(withAttributes: [.font: BrandFonts.nsSans(14, weight: .bold)]).width
    #expect(boldWidth > regularWidth)
}

/// Characters outside the latin subset (Ł, Š) come from the bundled latin-ext subset.
@MainActor @Test func brandSansFallsBackToLatinExt() {
    let font = BrandFonts.nsSans(14) as CTFont
    let text = "Łukasz Šimek" as CFString
    let run = CTFontCreateForString(font, text, CFRange(location: 0, length: 1))
    #expect(CTFontCopyFamilyName(run) as String == BrandFonts.sansFamily)
}
