import Foundation

/// A set of AWS keys, long-lived or temporary. Never log these: the
/// descriptions below redact everything but the first characters of the key
/// id, so a stray `print` or string interpolation can't leak them.
nonisolated struct AWSCredentials: Equatable, Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    /// Nil for long-lived keys; set for SSO, assumed roles and other temporary keys.
    let expiration: Date?

    init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}

nonisolated extension AWSCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        // The first four characters say only the key type (AKIA long-lived, ASIA temporary).
        let kind = String(accessKeyId.prefix(4))
        let expiry = expiration.map { " expires \($0)" } ?? ""
        return "AWSCredentials(\(kind)…, secret redacted\(sessionToken == nil ? "" : ", token redacted")\(expiry))"
    }

    var debugDescription: String { description }

    /// Keeps `dump()` and the debugger's child view from walking the stored properties.
    var customMirror: Mirror { Mirror(self, children: ["redacted": description]) }
}

/// Everything that can go wrong reaching AWS, worded by what the user has to do.
/// No case ever carries a key, secret, token or the CLI's stdout.
nonisolated enum AWSClientError: Error, Equatable, Sendable {
    /// No connection set up, the profile has no settings, or no keys are saved.
    case notConnected
    /// The profile needs the AWS CLI and it isn't installed.
    case cliMissing
    /// The SSO or role session behind this profile has expired (or needs MFA).
    /// The user renews it themselves, e.g. `aws sso login --profile NAME`; we
    /// never open a browser or answer a prompt for them.
    case needsSignIn(profile: String)
    /// AWS rejected the keys: expired, unknown, or the signature didn't match.
    case credentialsInvalid
    case accessDenied(message: String)
    /// Cost Explorer has never been switched on for this account.
    case costExplorerNotEnabled
    case network
    /// The profile name isn't one we're willing to hand to the CLI.
    case invalidProfileName(String)
    /// The CLI failed in a way that isn't a sign-in problem (timeout, bad output,
    /// unknown error). Carries a short, truncated piece of stderr at most.
    case cliFailed(message: String)
    /// Any other error AWS returned, with its code and message.
    case service(code: String, message: String)
}
