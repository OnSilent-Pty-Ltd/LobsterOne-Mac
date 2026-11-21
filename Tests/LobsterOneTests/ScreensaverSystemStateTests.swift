import Testing
import Foundation
@testable import LobsterOne

/// An Index.plist shaped like the one macOS 26 writes, with the given screensaver modules.
private func index(everywhere: String?, displays: [String: String] = [:], provider: String = ScreensaverSystemState.classicProvider) throws -> Data {
    func idle(_ module: String) throws -> [String: Any] {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["module": ["relative": module]], format: .binary, options: 0)
        return ["Idle": ["Content": ["Choices": [["Provider": provider, "Configuration": configuration, "Files": []]]]]]
    }
    var root: [String: Any] = ["Displays": try displays.mapValues(idle), "Spaces": [:]]
    if let everywhere { root["AllSpacesAndDisplays"] = try idle(everywhere) }
    return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}

private let ours = "file:///Users/me/Library/Screen%20Savers/LobsterOne.saver"
private let ventura = "file:///System/Library/ExtensionKit/Extensions/Ventura.appex"

@Test func indexWithLobsterOneIsActive() throws {
    #expect(ScreensaverSystemState.choice(fromIndex: try index(everywhere: ours)) == .lobsterOne)
}

@Test func indexWithAnotherModuleNamesIt() throws {
    #expect(ScreensaverSystemState.choice(fromIndex: try index(everywhere: ventura)) == .other("Ventura"))
    let aerial = "file:///Users/me/Library/Screen%20Savers/Aerial.saver"
    #expect(ScreensaverSystemState.choice(fromIndex: try index(everywhere: aerial)) == .other("Aerial"))
}

@Test func indexWithAnotherProviderHasNoName() throws {
    let data = try index(everywhere: ventura, provider: "com.apple.wallpaper.choice.aerials")
    #expect(ScreensaverSystemState.choice(fromIndex: data) == .other(nil))
}

@Test func lobsterOneOnOneDisplayCounts() throws {
    let data = try index(everywhere: ventura, displays: ["display-2": ours])
    #expect(ScreensaverSystemState.choice(fromIndex: data) == .lobsterOne)
    let none = try index(everywhere: nil, displays: ["display-2": ventura])
    #expect(ScreensaverSystemState.choice(fromIndex: none) == .other("Ventura"))
}

@Test func unreadableIndexIsUnknown() throws {
    #expect(ScreensaverSystemState.choice(fromIndex: Data()) == nil)
    #expect(ScreensaverSystemState.choice(fromIndex: Data("not a plist".utf8)) == nil)
    #expect(ScreensaverSystemState.choice(fromIndex: try index(everywhere: nil)) == nil)
}

@Test func moduleDictFallback() {
    #expect(ScreensaverSystemState.choice(fromModuleDict: ["path": "/Users/me/Library/Screen Savers/LobsterOne.saver", "moduleName": "LobsterOne"]) == .lobsterOne)
    #expect(ScreensaverSystemState.choice(fromModuleDict: ["path": "/System/Library/ExtensionKit/Extensions/Ventura.appex", "moduleName": "Ventura"]) == .other("Ventura"))
    #expect(ScreensaverSystemState.choice(fromModuleDict: ["moduleName": "Flurry"]) == .other("Flurry"))
    #expect(ScreensaverSystemState.choice(fromModuleDict: [:]) == nil)
    #expect(ScreensaverSystemState.choice(fromModuleDict: nil) == nil)
}

@Test func idleTimeWording() {
    #expect(ScreensaverSystemState.idleDuration(300) == "5 minutes")
    #expect(ScreensaverSystemState.idleDuration(60) == "1 minute")
    #expect(ScreensaverSystemState.idleDuration(3600) == "1 hour")
    #expect(ScreensaverSystemState.idleDuration(0) == nil)
    #expect(ScreensaverSystemState.idleDuration(nil) == nil)
    #expect(ScreensaverSystemState.timingTitle(300) == "Starts after 5 minutes idle")
    #expect(ScreensaverSystemState.timingTitle(0) == "Never starts on its own")
    #expect(ScreensaverSystemState.timingTitle(nil) == "Starts when your Mac is idle")
}
