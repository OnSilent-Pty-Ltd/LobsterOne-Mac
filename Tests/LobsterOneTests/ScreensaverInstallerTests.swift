import Testing
@testable import LobsterOne

@Test func installedSaverIsOnlyReplacedByANewerBuild() {
    #expect(ScreensaverInstaller.isNewer("142", than: "131"))
    #expect(ScreensaverInstaller.isNewer("131.10", than: "131.9"))
    #expect(ScreensaverInstaller.isNewer("131", than: nil))
    #expect(!ScreensaverInstaller.isNewer("131", than: "131"))
    #expect(!ScreensaverInstaller.isNewer("131.8", than: "131.9"))
}
