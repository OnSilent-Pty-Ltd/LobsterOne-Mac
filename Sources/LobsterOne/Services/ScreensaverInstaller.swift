import AppKit

/// Installs the screensaver the app carries in `Contents/Library/Screen Savers`, and keeps an
/// installed copy in step with app updates. Release builds carry it; local and SPM builds
/// usually do not, and then nothing here does anything.
@MainActor
enum ScreensaverInstaller {
    static let installedURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Screen Savers/LobsterOne.saver")

    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Screen Savers/LobsterOne.saver")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isInstalled: Bool { ScreensaverWatch.isInstalled }

    /// Copies the bundled screensaver into place, replacing any older copy. A silent update on
    /// launch leaves an open System Settings alone.
    static func install(quitSettings: Bool = true) throws {
        guard let bundledURL else { throw InstallError.notBundled }
        let folder = installedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Copy beside the target first, so a failed copy never leaves a half-written saver.
        let staging = folder.appendingPathComponent(".LobsterOne-\(UUID().uuidString).saver")
        try FileManager.default.copyItem(at: bundledURL, to: staging)
        if FileManager.default.fileExists(atPath: installedURL.path) {
            _ = try FileManager.default.replaceItemAt(installedURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: installedURL)
        }
        DebugLog.shared.log("Screensaver installed (build \(version(at: installedURL) ?? "?"))")
        refreshSystemList(quitSettings: quitSettings)
    }

    /// System Settings lists screensavers through a helper that scans the folder once, when it
    /// starts, and keeps running for hours; a saver added after that is missing from the list.
    /// Stopping the helper, and System Settings with it, makes the next visit rescan.
    static func refreshSystemList(quitSettings: Bool = true) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") where quitSettings {
            quitting.insert(app.processIdentifier)
            app.terminate()
        }
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["WallpaperLegacyExtension"]
        killall.standardOutput = FileHandle.nullDevice
        killall.standardError = FileHandle.nullDevice
        try? killall.run()
    }

    /// To the Trash, so it can be put back.
    static func remove() throws {
        try FileManager.default.trashItem(at: installedURL, resultingItemURL: nil)
        DebugLog.shared.log("Screensaver moved to the Trash")
        refreshSystemList()
    }

    /// On launch: an installed copy from an older app build is replaced. Someone who never
    /// installed it is left alone, and a newer copy is never downgraded.
    static func updateIfOutdated() {
        guard isInstalled, let bundledURL, let carried = version(at: bundledURL),
              isNewer(carried, than: version(at: installedURL)) else { return }
        do {
            try install(quitSettings: false)
        } catch {
            DebugLog.shared.log("Screensaver update failed: \(error.localizedDescription)")
        }
    }

    /// On macOS 26 the screen saver picker is a sheet in the Wallpaper pane. A link only reaches
    /// the pane; the sheet opens when System Settings is asked over Apple Events to reveal the
    /// pane's "ScreenSaver" anchor, which is what its own search does (Wallpaper.searchTerms).
    /// macOS does not let apps choose the screensaver for the user.
    static let paneURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!
    nonisolated static let revealPicker = """
        tell application "System Settings" to reveal anchor "ScreenSaver" of pane id "com.apple.Wallpaper-Settings.extension"
        """

    /// Opens the Wallpaper pane, then the picker sheet in it. Without permission to control
    /// System Settings (macOS asks once), it stops at the pane.
    /// Waits briefly for a System Settings that is quitting, so the link opens a fresh one.
    static func openScreenSaverSettings() {
        Task {
            for _ in 0..<30 {
                let stillQuitting = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                    .contains { !$0.isTerminated && quitting.contains($0.processIdentifier) }
                guard stillQuitting else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            quitting.removeAll()
            NSWorkspace.shared.open(paneURL)

            // A freshly launched System Settings can take the request before the pane is up;
            // asking again once it has loaded is harmless when the sheet is already showing.
            for delay in [1.0, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                // Off the main thread: the first time, the call waits on macOS's permission prompt.
                let error = await Task.detached { () -> String? in
                    var error: NSDictionary?
                    NSAppleScript(source: revealPicker)?.executeAndReturnError(&error)
                    return error.map { "\($0[NSAppleScript.errorNumber] ?? "?") \($0[NSAppleScript.errorMessage] ?? "")" }
                }.value
                if let error {
                    DebugLog.shared.log("Screen saver picker: could not reveal it (\(error)); System Settings stays on the Wallpaper pane")
                    return
                }
            }
        }
    }

    /// System Settings instances asked to quit by `refreshSystemList`.
    private static var quitting: Set<pid_t> = []

    /// The design picked in Settings, kept in the app's defaults and passed on in the snapshot.
    static var chosenStyle: ScreensaverStyle {
        get { UserDefaults.standard.string(forKey: "screensaverStyle").flatMap(ScreensaverStyle.init(rawValue:)) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "screensaverStyle") }
    }

    /// A still of each design for the picker in Settings (Resources/ScreensaverStyles).
    static func previewImage(_ style: ScreensaverStyle) -> NSImage? {
        let name = "style-\(style.rawValue)"
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "ScreensaverStyles").flatMap(NSImage.init(contentsOf:))
        #else
        // The Xcode project flattens resources into Contents/Resources; this also finds @2x.
        return Bundle.main.image(forResource: name)
        #endif
    }

    /// Build numbers compared as numbers, so "131.10" is newer than "131.9".
    nonisolated static func isNewer(_ candidate: String, than installed: String?) -> Bool {
        guard let installed else { return true }
        return candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    static func version(at url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// The installed copy's version as people see it ("2026.11.18"), for Settings.
    static var installedDisplayVersion: String? {
        guard let info = NSDictionary(contentsOf: installedURL.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String
    }

    /// Starts whichever screensaver macOS has chosen, now, the way a hot corner would.
    static func startNow() {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                DebugLog.shared.log("Screensaver preview failed: \(error.localizedDescription)")
            }
        }
    }

    enum InstallError: LocalizedError {
        case notBundled

        var errorDescription: String? { "This build of LobsterOne does not include the screensaver." }
    }
}
