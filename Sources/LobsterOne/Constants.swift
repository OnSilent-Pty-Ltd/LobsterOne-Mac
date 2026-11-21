import Foundation

/// Central place for environment URLs, polling/scanner cadences, and
/// vendor API headers. Keep in sync between `Sources/LobsterOne/` (SPM)
/// and `LobsterOne/LobsterOne/` (Xcode) — release builds use the Xcode
/// tree, so both must carry the same file.
enum Constants {
    // MARK: - Service URLs
    static let ingestURL = "https://ingest.lobsterone.ai"
    static let apiURL = "https://api.lobsterone.ai"
    static let appURL = "https://app.lobsterone.ai"
    /// The public page about LobsterOne for Teams.
    static let teamsURL = "https://lobsterone.ai/for-teams"

    // MARK: - Polling cadences (quota / backend sync)
    static let pollingActiveInterval: TimeInterval = 300   // 5 minutes
    static let pollingIdleInterval: TimeInterval = 900     // 15 minutes
    static let pollingScreensaverInterval: TimeInterval = 60  // while our screensaver is showing the numbers

    // MARK: - Local session scanner cadences
    static let scannerActiveInterval: TimeInterval = 60
    static let scannerIdleInterval: TimeInterval = 300

    // MARK: - Client policy
    static let clientPolicyDefaultsKey = "lobsterOne.clientPolicy"
    static let pollingBlockedInterval: TimeInterval = 60  // fast-poll while blocked, so unblocks recover quickly

    // MARK: - Vendor API headers
    static let anthropicOAuthBeta = "oauth-2025-04-20"
}
