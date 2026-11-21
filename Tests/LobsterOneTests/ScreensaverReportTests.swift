import Testing
@testable import LobsterOne

struct ScreensaverReportTests {
    private let installed = "/Users/me/Library/Screen Savers/LobsterOne.saver"
    private let bundled = "/Applications/LobsterOne.app/Contents/Library/Screen Savers/LobsterOne.saver"

    private func value(_ existing: Set<String>, style: String? = nil) -> String? {
        ScreensaverReport.headerValue(fileExists: { existing.contains($0) }, home: "/Users/me",
                                      bundlePath: "/Applications/LobsterOne.app", style: style)
    }

    @Test func installedReportsTheChosenStyle() {
        #expect(value([installed, bundled], style: "dashboard") == "installed; style=dashboard")
    }

    @Test func installedWithoutAChoiceReportsTheDefaultStyle() {
        #expect(value([installed]) == "installed; style=matrix")
    }

    @Test func releaseBuildWithoutTheSaverReportsNotInstalled() {
        #expect(value([bundled]) == "not-installed")
    }

    @Test func buildsWithoutTheSaverSendNothing() {
        #expect(value([]) == nil)
    }
}
