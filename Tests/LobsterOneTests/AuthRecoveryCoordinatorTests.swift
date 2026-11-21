// Tests/LobsterOneTests/AuthRecoveryCoordinatorTests.swift
import Testing
import Foundation
@testable import LobsterOne

final class FakeRecoveryEnv: AuthRecoveryEnvironment, @unchecked Sendable {
    var validateKeyResult = false
    var refreshSessionResult = false
    var reauthResult = false
    var remintResult = true
    var clock = Date(timeIntervalSince1970: 1000)

    var graceCount = 0
    var validateCount = 0
    var refreshCount = 0
    var reauthCount = 0
    var remintCount = 0
    var remintedSources: [String] = []

    func waitForHealGrace() async { graceCount += 1 }
    func validateKey(_ apiKey: String) async -> Bool { validateCount += 1; return validateKeyResult }
    func refreshSession() async -> Bool { refreshCount += 1; return refreshSessionResult }
    func reauthenticateInteractively() async -> Bool { reauthCount += 1; return reauthResult }
    func remintKey(sourceType: String) async -> Bool {
        remintCount += 1
        if remintResult { remintedSources.append(sourceType) }
        return remintResult
    }
    func now() -> Date { clock }
    func log(_ message: String) {}
}

@Test func healedExternally_whenKeyValidatesOnRecheck() async {
    let env = FakeRecoveryEnv(); env.validateKeyResult = true
    let c = AuthRecoveryCoordinator(env: env)
    let outcome = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(outcome == .healedExternally)
    #expect(env.graceCount == 1)
    #expect(env.remintCount == 0)
    #expect(env.refreshCount == 0)
}

@Test func silentRemint_whenSessionRefreshSucceeds() async {
    let env = FakeRecoveryEnv()
    env.validateKeyResult = false; env.refreshSessionResult = true; env.remintResult = true
    let c = AuthRecoveryCoordinator(env: env)
    let outcome = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(outcome == .reminted)
    #expect(env.reauthCount == 0)            // no popup when refresh works
    #expect(env.remintedSources == ["codex"])
}

@Test func popupPath_whenRefreshDeadButReauthSucceeds() async {
    let env = FakeRecoveryEnv()
    env.validateKeyResult = false; env.refreshSessionResult = false
    env.reauthResult = true; env.remintResult = true
    let c = AuthRecoveryCoordinator(env: env)
    let outcome = await c.handleAuthFailure(sourceType: "claude-code", apiKey: "rc_x")
    #expect(outcome == .reminted)
    #expect(env.reauthCount == 1)
    #expect(env.remintedSources == ["claude-code"])
}

@Test func failedReauth_whenRefreshAndReauthBothFail() async {
    let env = FakeRecoveryEnv()
    env.validateKeyResult = false; env.refreshSessionResult = false; env.reauthResult = false
    let c = AuthRecoveryCoordinator(env: env)
    let outcome = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(outcome == .failedReauth)
    #expect(env.remintCount == 0)
}

@Test func failedRemint_whenMintFails() async {
    let env = FakeRecoveryEnv()
    env.validateKeyResult = false; env.refreshSessionResult = true; env.remintResult = false
    let c = AuthRecoveryCoordinator(env: env)
    let outcome = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(outcome == .failedRemint)
}

/// A `FakeRecoveryEnv` variant that parks inside `waitForHealGrace()` until
/// the test explicitly releases it. Used to keep the first call in-flight
/// so we can verify a concurrent second call returns `.skippedInFlight`.
final class GatedRecoveryEnv: AuthRecoveryEnvironment, @unchecked Sendable {
    var validateKeyResult = false
    var refreshSessionResult = false
    var remintResult = true

    // Signalled when the first call has entered waitForHealGrace.
    private var enteredCont: CheckedContinuation<Void, Never>?
    private let enteredLock = NSLock()
    // Signalled when the test is ready to let waitForHealGrace return.
    private var releaseCont: CheckedContinuation<Void, Never>?
    private let releaseLock = NSLock()

    /// Block until the first call is parked inside `waitForHealGrace`.
    func waitUntilInGrace() async {
        await withCheckedContinuation { cont in
            enteredLock.lock()
            enteredCont = cont
            enteredLock.unlock()
        }
    }

    /// Release the parked `waitForHealGrace` call.
    func releaseGrace() {
        releaseLock.lock()
        let cont = releaseCont
        releaseCont = nil
        releaseLock.unlock()
        cont?.resume()
    }

    func waitForHealGrace() async {
        // Signal the test we've entered, then wait for the release.
        await withCheckedContinuation { cont in
            releaseLock.lock()
            releaseCont = cont
            releaseLock.unlock()
            enteredLock.lock()
            let e = enteredCont
            enteredCont = nil
            enteredLock.unlock()
            e?.resume()
        }
    }

    func validateKey(_ apiKey: String) async -> Bool { validateKeyResult }
    func refreshSession() async -> Bool { refreshSessionResult }
    func reauthenticateInteractively() async -> Bool { false }
    func remintKey(sourceType: String) async -> Bool { remintResult }
    func now() -> Date { Date() }
    func log(_ message: String) {}
}

@Test func skippedInFlight_whenSecondCallOverlapsFirst() async {
    // Gate the first call inside waitForHealGrace so it stays in-flight.
    let env = GatedRecoveryEnv()
    env.validateKeyResult = false; env.refreshSessionResult = true; env.remintResult = true
    let c = AuthRecoveryCoordinator(env: env)

    async let first = c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    await env.waitUntilInGrace()                 // first call is now parked in waitForHealGrace
    let second = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(second == .skippedInFlight)
    env.releaseGrace()                            // let the first call finish
    #expect(await first == .reminted)
}

@Test func capped_blocksSecondRemintWithinWindow_thenAllowsAfter() async {
    let env = FakeRecoveryEnv()
    env.validateKeyResult = false; env.refreshSessionResult = true; env.remintResult = true
    let c = AuthRecoveryCoordinator(env: env, remintCap: 600)

    let first = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(first == .reminted)

    env.clock = env.clock.addingTimeInterval(300)   // within cap
    let second = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(second == .skippedCapped)
    #expect(env.remintCount == 1)

    env.clock = env.clock.addingTimeInterval(400)   // now 700s > cap
    let third = await c.handleAuthFailure(sourceType: "codex", apiKey: "rc_x")
    #expect(third == .reminted)
    #expect(env.remintCount == 2)
}
