import Foundation

/// Which screensaver macOS shows and after how long, read from the system's own files so the
/// Screensaver tab can say whether LobsterOne is actually in use. Only ever reads.
struct ScreensaverSystemState: Equatable {
    enum Choice: Equatable {
        /// LobsterOne is the screensaver, everywhere or on at least one display.
        case lobsterOne
        /// Something else is; its name when the system says which ("Ventura", "Aerial").
        case other(String?)
        /// Neither file could be read, so the tab doesn't claim either way.
        case unknown
    }

    var choice: Choice
    /// Seconds idle before it starts; 0 is never, nil when the setting isn't there.
    var idleSeconds: Int?

    /// The wallpaper store macOS 14 and later keep the screensaver choice in.
    static let indexURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static func read() -> ScreensaverSystemState {
        let fromIndex = (try? Data(contentsOf: indexURL)).flatMap(choice(fromIndex:))
        let choice = fromIndex
            ?? choice(fromModuleDict: preference("moduleDict") as? [String: Any])
            ?? .unknown
        return ScreensaverSystemState(choice: choice, idleSeconds: (preference("idleTime") as? NSNumber)?.intValue)
    }

    private static func preference(_ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, "com.apple.screensaver" as CFString,
                               kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    // MARK: Parsing

    static let classicProvider = "com.apple.wallpaper.choice.screen-saver"
    private static let saverName = "LobsterOne"

    /// The choice in a copy of Index.plist, or nil when it can't be read. LobsterOne counts as
    /// chosen if the all-displays entry or any single display uses it.
    static func choice(fromIndex data: Data) -> Choice? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        // With nothing set for all displays, the system default is what shows on them.
        let everywhere = (root["AllSpacesAndDisplays"] as? [String: Any]).flatMap(idleChoice)
            ?? (root["SystemDefault"] as? [String: Any]).flatMap(idleChoice)
        let displays = ((root["Displays"] as? [String: Any]) ?? [:])
            .sorted { $0.key < $1.key }
            .compactMap { ($0.value as? [String: Any]).flatMap(idleChoice) }
        let all = [everywhere].compactMap { $0 } + displays
        if all.contains(.lobsterOne) { return .lobsterOne }
        return all.first
    }

    /// One `Idle` entry: the first choice's provider and, for classic modules, the module's file.
    private static func idleChoice(_ entry: [String: Any]) -> Choice? {
        guard let idle = entry["Idle"] as? [String: Any],
              let content = idle["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first,
              let provider = first["Provider"] as? String
        else { return nil }
        guard provider == classicProvider else { return .other(nil) }
        guard let data = first["Configuration"] as? Data, !data.isEmpty,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let module = configuration["module"] as? [String: Any],
              let relative = module["relative"] as? String,
              let url = URL(string: relative)
        else { return .other(nil) }
        return choice(moduleFile: url.lastPathComponent)
    }

    /// The older preference: `moduleDict` with the module's path and name. Nil when absent.
    static func choice(fromModuleDict dict: [String: Any]?) -> Choice? {
        guard let dict else { return nil }
        if let path = dict["path"] as? String, !path.isEmpty {
            return choice(moduleFile: URL(fileURLWithPath: path).lastPathComponent)
        }
        if let name = dict["moduleName"] as? String, !name.isEmpty {
            return name == saverName ? .lobsterOne : .other(name)
        }
        return nil
    }

    private static func choice(moduleFile: String) -> Choice {
        if moduleFile == "\(saverName).saver" { return .lobsterOne }
        let name = (moduleFile as NSString).deletingPathExtension
        return .other(name.isEmpty ? nil : name)
    }

    // MARK: Wording

    /// "5 minutes", "1 minute", "1 hour"; nil for never (0) or not set.
    static func idleDuration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// The timing row's headline.
    static func timingTitle(_ seconds: Int?) -> String {
        if seconds == 0 { return "Never starts on its own" }
        if let duration = idleDuration(seconds) { return "Starts after \(duration) idle" }
        return "Starts when your Mac is idle"
    }
}
