import Foundation

/// Outcome of one recovery attempt. Returned for testability and so the caller
/// can decide whether to fall back to a destructive sign-out.
enum RecoveryOutcome: Equatable {
    case skippedInFlight    // a recovery for this source is already running
    case skippedCapped      // re-minted too recently (within the per-source cap)
    case healedExternally   // key validated on re-check (Layer 1 / transient) — no action
    case reminted           // minted a fresh key, wrote config, restarted the scanner
    case failedReauth       // session dead and interactive sign-in failed/cancelled
    case failedRemint       // session ok but minting/writing the new key failed
}

/// Side effects the coordinator needs, behind a protocol so the state machine is
/// unit-testable with a fake. The live implementation hops to the main actor.
protocol AuthRecoveryEnvironment: Sendable {
    /// Debounce window so a transient / Layer-1-healed 403 doesn't trigger churn.
    func waitForHealGrace() async
    /// Re-check the key against /v1/instance/status. true = backend accepts it.
    func validateKey(_ apiKey: String) async -> Bool
    /// Refresh the Cognito session in place (preserving the refresh token). true = valid.
    func refreshSession() async -> Bool
    /// Interactive OAuth sign-in, persisting tokens WITHOUT destroying keys/config. true = success.
    func reauthenticateInteractively() async -> Bool
    /// Mint a new key for the source, write its config, restart its scanner. true = success.
    func remintKey(sourceType: String) async -> Bool
    /// Injectable clock for the per-source cap.
    func now() -> Date
    func log(_ message: String)
}

/// Recovers from a persistent 401/403 on a source's key WITHOUT a destructive
/// full Sign Out: silently re-mints in place, prompting an in-place sign-in only
/// if the refresh token itself is dead. Serializes per source and rate-limits
/// re-mints so a backend that keeps 403'ing can't drive a key-churn loop.
actor AuthRecoveryCoordinator {
    private let env: AuthRecoveryEnvironment
    private let remintCap: TimeInterval
    private var inFlight: Set<String> = []
    private var lastRemint: [String: Date] = [:]

    init(env: AuthRecoveryEnvironment, remintCap: TimeInterval = 600) {
        self.env = env
        self.remintCap = remintCap
    }

    /// Handle a persistent auth failure for one source. Idempotent under
    /// concurrent calls for the same source; safe to call every poll cycle.
    @discardableResult
    func handleAuthFailure(sourceType: String, apiKey: String) async -> RecoveryOutcome {
        if inFlight.contains(sourceType) { return .skippedInFlight }
        if let last = lastRemint[sourceType], env.now().timeIntervalSince(last) < remintCap {
            return .skippedCapped
        }
        inFlight.insert(sourceType)
        defer { inFlight.remove(sourceType) }

        // Debounce, then confirm the failure is real (not transient / Layer-1-healed).
        await env.waitForHealGrace()
        if await env.validateKey(apiKey) {
            env.log("Auth recovery [\(sourceType)]: key valid on re-check — no action")
            return .healedExternally
        }

        // Ensure a usable session: refresh in place, else interactive sign-in.
        if await env.refreshSession() {
            env.log("Auth recovery [\(sourceType)]: session refreshed, re-minting")
        } else if await env.reauthenticateInteractively() {
            env.log("Auth recovery [\(sourceType)]: re-authenticated, re-minting")
        } else {
            env.log("Auth recovery [\(sourceType)]: re-authentication failed")
            return .failedReauth
        }

        if await env.remintKey(sourceType: sourceType) {
            lastRemint[sourceType] = env.now()
            env.log("Auth recovery [\(sourceType)]: re-minted key in place")
            return .reminted
        }
        env.log("Auth recovery [\(sourceType)]: re-mint failed")
        return .failedRemint
    }
}
