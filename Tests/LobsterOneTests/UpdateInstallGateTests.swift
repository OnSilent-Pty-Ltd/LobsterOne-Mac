import Testing
@testable import LobsterOne

@Test @MainActor func updateWaitsWhileInterfaceOpen() {
    #expect(!UpdateInstallGate.canInstall(idleSeconds: 3600, interfaceOpen: true))
}

@Test @MainActor func updateWaitsWhilePersonIsActive() {
    #expect(!UpdateInstallGate.canInstall(idleSeconds: 30, interfaceOpen: false))
}

@Test @MainActor func updateInstallsWhenAway() {
    #expect(UpdateInstallGate.canInstall(idleSeconds: UpdateInstallGate.requiredIdle, interfaceOpen: false))
}

@MainActor @Test func askingForUpdatesInstallsAHeldOneAtOnce() {
    let gate = UpdateInstallGate()
    #expect(!gate.installNow()) // nothing held: the caller runs a normal check
    var installed = 0
    gate.hold { installed += 1 }
    #expect(gate.hasPendingInstall)
    #expect(gate.installNow())
    #expect(installed == 1 && !gate.hasPendingInstall)
    #expect(!gate.installNow()) // only once
}
