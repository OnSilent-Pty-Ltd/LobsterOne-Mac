import Foundation
import Testing
@testable import LobsterOne

/// Stands in for the Mac: records what the guide asks of it and keeps the state those calls change.
@MainActor
private final class FakeMac {
    let defaults = UserDefaults(suiteName: "SetupGuideTests-\(UUID().uuidString)")!
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("SetupGuideTests-\(UUID().uuidString)")
    var tools: [SetupGuide.Tool: SetupGuide.ToolPresence] = [
        .claudeCode: .init(installed: true, connected: true),
        .codex: .init(installed: true, connected: false),
        .mistralVibe: .init(installed: false, connected: false),
    ]
    var connectError: Error?
    var dictation = false
    var microphone: String?
    var paceAlerts = true
    var permission: PaceNotifier.Permission = .notAsked
    var screensaverInstalled = false
    var style = ScreensaverStyle.standard
    var calls: [String] = []

    init() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: SetupGuide.Environment {
        SetupGuide.Environment(
            defaults: defaults,
            home: home,
            detectTools: { self.tools },
            connectTool: { tool in
                self.calls.append("connect \(tool.rawValue)")
                if let error = self.connectError { throw error }
            },
            disconnectTool: { self.calls.append("disconnect \($0.rawValue)") },
            previewSound: { _, _ in self.calls.append("preview") },
            dictationEnabled: { self.dictation },
            setDictationEnabled: { self.dictation = $0; self.calls.append("dictation \($0)") },
            microphones: { [] },
            systemMicrophoneName: { nil },
            selectedMicrophone: { self.microphone },
            setMicrophone: { self.microphone = $0; self.calls.append("microphone \($0 ?? "default")") },
            paceAlertsEnabled: { self.paceAlerts },
            setPaceAlertsEnabled: { self.paceAlerts = $0; self.calls.append("alerts \($0)") },
            notificationPermission: { self.permission },
            requestNotificationPermission: { self.calls.append("ask"); self.permission = .allowed },
            screensaverAvailable: { true },
            screensaverInstalled: { self.screensaverInstalled },
            screensaverStyle: { self.style },
            setScreensaverStyle: { self.style = $0; self.calls.append("style \($0.rawValue)") },
            installScreensaver: { self.screensaverInstalled = true; self.calls.append("install") },
            awsConnected: { false })
    }

    /// A guide already past sign-in, on the given step, with the tools found.
    func guide(at step: SetupGuide.Step) async -> SetupGuide {
        let guide = SetupGuide(env: env, startAt: .tools)
        await guide.detectTools()
        while guide.step < step { guide.skip() }
        return guide
    }

    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
}

@MainActor @Test func setupGuideTracksWhatIsInstalledByDefault() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .tools)
    #expect(guide.tracked == [.claudeCode, .codex])
    #expect(mac.calls.isEmpty)
}

@MainActor @Test func setupGuideToolsAreConnectedAndDisconnectedOnceOnConfirm() async {
    let mac = FakeMac()
    mac.tools[.codex] = .init(installed: true, connected: false)
    let guide = await mac.guide(at: .tools)
    guide.tracked = [.codex]
    await guide.confirm()
    #expect(mac.calls == ["disconnect claude-code", "connect codex"])
    #expect(guide.step == .sounds)
    #expect(guide.outcomes[.tools] == .on("Codex"))

    // Back and confirm again: already as chosen, so nothing more happens.
    guide.back()
    await guide.confirm()
    #expect(mac.calls == ["disconnect claude-code", "connect codex"])
}

@MainActor @Test func setupGuideStaysOnToolsWhenAConnectionFails() async {
    let mac = FakeMac()
    mac.connectError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"])
    let guide = await mac.guide(at: .tools)
    await guide.confirm()
    #expect(guide.step == .tools)
    #expect(guide.problem?.contains("Codex: offline") == true)
}

@MainActor @Test func setupGuideSoundsWriteHooksOnlyOnConfirmAndOnlyOnce() async throws {
    let mac = FakeMac()
    let guide = await mac.guide(at: .sounds)
    #expect(guide.packID == "garry")
    guide.choosePack("redalert")
    #expect(mac.calls == ["preview"])
    #expect(!FileManager.default.fileExists(atPath: mac.claudeSettings.path))

    await guide.confirm()
    let settings = SoundCueSettings.load(mac.defaults)
    #expect(settings.enabled)
    #expect(settings.pack?.id == "redalert")
    #expect(settings.tools == [.claude, .codex])
    let written = try String(contentsOf: mac.claudeSettings, encoding: .utf8)
    #expect(written.contains(SoundCueInstaller.marker))

    guide.back()
    let modified = try FileManager.default.attributesOfItem(atPath: mac.claudeSettings.path)[.modificationDate] as? Date
    await guide.confirm()
    let after = try FileManager.default.attributesOfItem(atPath: mac.claudeSettings.path)[.modificationDate] as? Date
    #expect(modified == after)
}

@MainActor @Test func setupGuideNoSoundsOnANewMacWritesNothing() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .sounds)
    guide.choosePack(nil)
    await guide.confirm()
    #expect(mac.defaults.object(forKey: SoundCueSettings.defaultsKey) == nil)
    #expect(!FileManager.default.fileExists(atPath: mac.claudeSettings.path))
    #expect(guide.outcomes[.sounds] == .off("No sounds"))
}

@MainActor @Test func setupGuideNotNowChangesNothing() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .tools)
    while guide.step < .done { guide.skip() }
    #expect(mac.calls.isEmpty)
    #expect(mac.defaults.object(forKey: SoundCueSettings.defaultsKey) == nil)
    #expect(guide.outcomes.values.allSatisfy { $0 == .skipped })
    #expect(!guide.wantsAWS)
}

@MainActor @Test func setupGuideDictationAppliesThroughTheControllerOnce() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .dictation)
    guide.dictationOn = true
    guide.microphoneUID = "usb-mic"
    #expect(mac.calls.isEmpty)
    await guide.confirm()
    #expect(mac.calls == ["microphone usb-mic", "dictation true"])
    guide.back()
    await guide.confirm()
    #expect(mac.calls == ["microphone usb-mic", "dictation true"])
}

@MainActor @Test func setupGuideAlertsAskMacOSOnlyWhenConfirmed() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .alerts)
    #expect(!mac.calls.contains("ask"))
    await guide.confirm()
    #expect(mac.calls == ["ask"])
    #expect(guide.outcomes[.alerts] == .on("On"))

    // Off: saved, and macOS isn't asked again.
    guide.back()
    guide.paceAlertsOn = false
    await guide.confirm()
    #expect(mac.calls == ["ask", "alerts false"])
}

@MainActor @Test func setupGuideScreensaverInstallsOnceWithTheChosenDesign() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .screensaver)
    guide.screensaverStyle = .den
    await guide.confirm()
    #expect(mac.calls == ["style den", "install"])
    guide.back()
    await guide.confirm()
    #expect(mac.calls == ["style den", "install"])
}

@MainActor @Test func setupGuideAWSOpensSettingsOnlyWhenAskedFor() async {
    let mac = FakeMac()
    let guide = await mac.guide(at: .aws)
    await guide.confirm()
    #expect(guide.wantsAWS)
    guide.back()
    guide.skip()
    #expect(!guide.wantsAWS)
}

@MainActor @Test func setupGuideShowsOnlyOnAMacThatHasNotBeenSetUp() {
    let fresh = UserDefaults(suiteName: "SetupGuideTests-\(UUID().uuidString)")!
    #expect(SetupGuide.shouldShowAfterSignIn(fresh))

    // Someone signed in when this version first launches already uses the app.
    let existing = UserDefaults(suiteName: "SetupGuideTests-\(UUID().uuidString)")!
    SetupGuide.noteLaunch(signedIn: true, defaults: existing)
    #expect(!SetupGuide.shouldShowAfterSignIn(existing))

    let signedOut = UserDefaults(suiteName: "SetupGuideTests-\(UUID().uuidString)")!
    SetupGuide.noteLaunch(signedIn: false, defaults: signedOut)
    #expect(SetupGuide.shouldShowAfterSignIn(signedOut))

    // Signed out at the update, but with settings of their own.
    signedOut.set(false, forKey: PaceNotifier.enabledKey)
    #expect(!SetupGuide.shouldShowAfterSignIn(signedOut))
}

@MainActor @Test func setupGuideIsSeenOnceItBeginsSoASecondSignInSkipsIt() {
    let mac = FakeMac()
    let guide = SetupGuide(env: mac.env)
    #expect(SetupGuide.shouldShowAfterSignIn(mac.defaults))
    guide.begin()
    #expect(guide.step == .tools)
    #expect(!SetupGuide.shouldShowAfterSignIn(mac.defaults))
}

@Test func configServiceFindsClaudeCodeByItsFolder() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("SetupGuideTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    #expect(ConfigService(homeDirectory: home).isClaudeCodeInstalled())
}
