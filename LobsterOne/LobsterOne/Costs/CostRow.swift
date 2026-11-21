import Foundation

nonisolated enum CostError: Error, Equatable, Sendable {
    /// No AWS connection has been set up.
    case notConnected
    /// An SSO or role sign-in has expired. Renewing it opens the browser, so only the person
    /// can do it; a background refresh must never try.
    case needsSignIn(profile: String?)
    /// The profile gets its credentials through the aws CLI, which isn't installed.
    case cliMissing
    /// Cost Explorer hasn't been switched on for this AWS account yet.
    case notEnabled
    case accessDenied
    /// The saved keys are wrong or were deleted in AWS.
    case credentialsInvalid
    case network
    case other(String)

    /// Maps any error from a fetch to a `CostError`. The AWS client throws `CostError` itself
    /// wherever it knows better; this only covers what it passes through.
    static func explain(_ error: Error) -> CostError {
        if let e = error as? CostError { return e }
        if (error as NSError).domain == NSURLErrorDomain { return .network }
        return .other(String(describing: error))
    }

    /// Maps an AWS error code and message. `profile` is the profile in use, so an expired
    /// sign-in can name the command that renews it.
    static func explain(code: String, message: String?, profile: String? = nil) -> CostError {
        let msg = (message ?? "").lowercased()
        switch code {
        case "AccessDeniedException", "AccessDenied":
            // AWS's wording when Cost Explorer has never been opened.
            if msg.contains("not enabled for cost explorer") { return .notEnabled }
            return .accessDenied
        case "DataUnavailableException":
            return .notEnabled
        // Temporary credentials from SSO or an assumed role have run out. The SSO portal
        // answers UnauthorizedException once its cached token is no longer valid.
        case "ExpiredToken", "ExpiredTokenException", "UnauthorizedException", "InvalidGrantException":
            return .needsSignIn(profile: profile)
        case "UnrecognizedClientException", "InvalidClientTokenId", "SignatureDoesNotMatch":
            return .credentialsInvalid
        default:
            return .other(message ?? code)
        }
    }
}

protocol CostFetching: Sendable {
    func fetch(now: Date) async throws -> CostSnapshot
}

/// One account's spend in one month, as Cost Explorer returns it.
nonisolated struct CostRow: Equatable, Sendable {
    let periodStart: String
    let account: String
    let amount: Double
    let unit: String
    let estimated: Bool

    static func snapshot(_ rows: [CostRow], now: Date) -> CostSnapshot {
        let thisMonth = CostMath.month(now)
        var current: [String: Double] = [:], previous: [String: Double] = [:]
        for r in rows {
            if r.periodStart.hasPrefix(thisMonth) { current[r.account, default: 0] += r.amount }
            else { previous[r.account, default: 0] += r.amount }
        }
        return CostSnapshot(fetchedAt: now, currency: rows.first?.unit ?? "USD", month: thisMonth,
                            thisMonth: current, lastMonth: previous,
                            estimated: rows.contains { $0.periodStart.hasPrefix(thisMonth) && $0.estimated })
    }
}
