import Foundation

/// What this Mac tells the API about the screensaver, sent with each status poll as
/// `X-LobsterOne-Screensaver`, so the dashboard and the popover can invite people who
/// have not installed it yet.
enum ScreensaverReport {
    static let headerName = "X-LobsterOne-Screensaver"

    /// "installed; style=<style>" or "not-installed". Nil when this build carries no
    /// screensaver and none is installed (local and SPM builds), so no invite follows.
    static func headerValue(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        home: String = NSHomeDirectory(),
        bundlePath: String = Bundle.main.bundlePath,
        style: String? = UserDefaults.standard.string(forKey: "screensaverStyle")
    ) -> String? {
        if fileExists(home + "/Library/Screen Savers/LobsterOne.saver") {
            return "installed; style=\(style ?? ScreensaverStyle.standard.rawValue)"
        }
        guard fileExists(bundlePath + "/Contents/Library/Screen Savers/LobsterOne.saver") else { return nil }
        return "not-installed"
    }
}
