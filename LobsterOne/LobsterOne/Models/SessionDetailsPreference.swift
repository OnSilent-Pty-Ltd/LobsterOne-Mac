import Foundation

/// Whether Claude Code session uploads carry the details that tell sessions apart: the first
/// 500 characters of the first prompt, the session title and the paths of files touched. They
/// let people sort their token use by project and client on the dashboard. On by default; off
/// sends usage numbers, the project folder and the git branch only.
nonisolated enum SessionDetailsPreference {
    static let key = "sendSessionDetails"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
