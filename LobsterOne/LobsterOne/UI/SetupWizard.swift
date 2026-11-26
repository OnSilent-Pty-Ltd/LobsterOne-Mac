import SwiftUI

enum SetupStep {
    case welcome
    case signingIn
    case pickInstance(instances: [Instance], newKeyResponse: CreateAPIKeyResponse, idToken: String, refreshToken: String, email: String?)
    case complete(email: String, planTier: String)
    case error(message: String)
}

/// The first-run window: sign-in, then, on a Mac that hasn't been set up, the setup guide's
/// choices (`SetupGuideScreen`). Progress across the top; Back, "Not now" and the one primary
/// button along the bottom, in the same places on every screen.
struct SetupWizard: View {
    static let size = CGSize(width: 720, height: 550)
    static let sideMargin: CGFloat = 32

    @ObservedObject var guide: SetupGuide
    @State private var step: SetupStep
    /// The instance picked to link this Mac to, before the person confirms it.
    @State private var linkTo: Instance.ID?
    let dictation: DictationController?
    /// Sign-in is saved: the app starts monitoring now, so closing the window part-way loses nothing.
    let onSignedIn: () -> Void
    /// The last button. True when the person asked to set up AWS, so Settings opens on it.
    let onFinish: (_ openAWS: Bool) -> Void

    private let authService: AuthService
    private let apiClient: APIClient

    @MainActor init(guide: SetupGuide,
                    dictation: DictationController? = nil,
                    signIn: SetupStep = .welcome,
                    authService: AuthService = AuthService(),
                    apiClient: APIClient = APIClient(),
                    onSignedIn: @escaping () -> Void = {},
                    onFinish: @escaping (_ openAWS: Bool) -> Void) {
        self.guide = guide
        self._step = State(initialValue: signIn)
        self.dictation = dictation
        self.authService = authService
        self.apiClient = apiClient
        self.onSignedIn = onSignedIn
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if guide.step == .signIn {
                    signInContent
                } else {
                    SetupGuideScreen(guide: guide, dictation: dictation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            if guide.step != .signIn {
                ClawMark(size: 16)
                Text("LobsterOne")
                    .font(BrandFonts.sans(14, weight: .semibold))
                    .tracking(-0.02 * 14)
            }
            Spacer(minLength: 12)
            if showsProgress {
                StepDots(current: guide.step.number, count: SetupGuide.Step.count)
                Text("\(guide.step.number) of \(SetupGuide.Step.count)")
                    .font(BrandFonts.sans(12.5, weight: .medium))
                    .foregroundStyle(PopoverPalette.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsProgress ? "Step \(guide.step.number) of \(SetupGuide.Step.count)" : "LobsterOne setup")
    }

    private struct Action {
        let title: String
        var enabled = true
        let run: () -> Void
    }

    private var footer: some View {
        let (primary, secondary) = actions
        return HStack(spacing: 10) {
            Button { guide.back() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Back").font(BrandFonts.sans(13, weight: .semibold))
                }
                .foregroundStyle(PopoverPalette.secondary)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsBack ? 1 : 0)
            .disabled(!showsBack)
            .accessibilityHidden(!showsBack)

            Spacer(minLength: 8)

            if let secondary {
                SettingsPill(title: secondary.title, prominent: false, action: secondary.run)
                    .disabled(!secondary.enabled)
                    .opacity(secondary.enabled ? 1 : 0.5)
            }
            // Disabled, it drops to the outline style: still readable, plainly not ready.
            SettingsPill(title: primary.title, prominent: primary.enabled, action: primary.run)
                .keyboardShortcut(.defaultAction)
                .disabled(!primary.enabled)
                .opacity(primary.enabled ? 1 : 0.8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }
    }

    /// Someone whose Mac was set up before signs in and goes straight to work, so "1 of 8"
    /// would promise steps they'll never see.
    private var showsProgress: Bool {
        guard guide.step == .signIn else { return true }
        if case .complete = step { return false }
        return SetupGuide.shouldShowAfterSignIn(guide.env.defaults)
    }

    private var showsBack: Bool { guide.step != .signIn && guide.canGoBack }

    /// The primary and secondary buttons for what's on screen.
    private var actions: (Action, Action?) {
        let confirm: () -> Void = { Task { await guide.confirm() } }
        let notNow = Action(title: "Not now", enabled: !guide.isApplying) { guide.skip() }
        switch guide.step {
        case .signIn:
            switch step {
            case .welcome:
                return (Action(title: "Get started") { startSignIn() }, nil)
            case .signingIn:
                return (Action(title: "Waiting for the browser\u{2026}", enabled: false) {}, nil)
            case .pickInstance(let instances, let newKey, let idToken, let refreshToken, let email):
                let chosen = instances.first { $0.id == linkTo }
                return (Action(title: "Link this Mac", enabled: chosen != nil) {
                            if let chosen {
                                linkToInstance(instance: chosen, newKey: newKey, idToken: idToken, refreshToken: refreshToken, email: email)
                            }
                        },
                        Action(title: "Start fresh") {
                            finishSetup(newKey: newKey, idToken: idToken, refreshToken: refreshToken, email: email)
                        })
            case .complete:
                return (Action(title: "Start monitoring") { onFinish(false) }, nil)
            case .error:
                return (Action(title: "Try again") { step = .welcome }, nil)
            }
        case .tools:
            return (Action(title: guide.isApplying ? "Connecting\u{2026}" : "Continue",
                           enabled: guide.tools != nil && !guide.isApplying, run: confirm), notNow)
        case .claudeCode:
            switch guide.claudeCodeMod {
            case nil:
                return (Action(title: "Asking Claude Code\u{2026}", enabled: false) {}, notNow)
            case .claudeMissing, .notBundled, .installed:
                return (Action(title: "Continue", run: confirm), nil)
            case .switchedOff:
                return (Action(title: guide.isApplying ? "Turning on\u{2026}" : "Turn back on",
                               enabled: !guide.isApplying, run: confirm), notNow)
            case .notInstalled:
                let title = guide.isApplying ? "Adding\u{2026}" : guide.problem == nil ? "Add to Claude Code" : "Try again"
                return (Action(title: title, enabled: !guide.isApplying, run: confirm), notNow)
            }
        case .sounds:
            return (Action(title: guide.chosenPack == nil ? "Continue" : "Use these sounds", run: confirm), notNow)
        case .dictation:
            let available = dictation?.availability == .available
            let turnsOn = available && guide.dictationOn && !guide.env.dictationEnabled()
            return (Action(title: turnsOn ? "Turn on dictation" : "Continue", run: available ? confirm : { guide.skip(.off("Not available on this Mac")) }),
                    available ? notNow : nil)
        case .alerts:
            return (Action(title: guide.paceAlertsOn && guide.notificationPermission == .notAsked ? "Turn on alerts" : "Continue",
                           enabled: !guide.isApplying, run: confirm), notNow)
        case .screensaver:
            guard guide.screensaverAvailable else { return (Action(title: "Continue", run: confirm), nil) }
            return (Action(title: guide.screensaverInstalled ? "Use this design" : "Install screensaver", run: confirm), notNow)
        case .aws:
            guard !guide.awsConnected else { return (Action(title: "Continue", run: confirm), nil) }
            return (Action(title: "Set up AWS", run: confirm), notNow)
        case .done:
            return (Action(title: guide.firstStep == .signIn ? "Start monitoring" : "Done") { onFinish(guide.wantsAWS) }, nil)
        }
    }

    // MARK: Sign-in screens

    @ViewBuilder
    private var signInContent: some View {
        switch step {
        case .welcome:
            welcomeView
        case .signingIn:
            signingInView
        case .pickInstance(let instances, _, _, _, _):
            instancePickerView(instances: instances)
        case .complete(let email, let planTier):
            completeView(email: email, planTier: planTier)
        case .error(let message):
            errorView(message: message)
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            GarryOnHisLine(walking: true, scale: 1.3)
                .padding(.bottom, 22)
            Text("LobsterOne")
                .font(BrandFonts.sans(30, weight: .bold))
                .tracking(-0.03 * 30)
                .accessibilityAddTraits(.isHeader)
            Text("Know where every token goes.")
                .font(BrandFonts.sans(15))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.top, 6)
            Text("Signing in opens your browser. A few optional choices follow, each one skippable.")
                .font(BrandFonts.sans(13))
                .foregroundStyle(PopoverPalette.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.top, 18)

            HStack(spacing: 4) {
                Text("Already have an account?")
                    .foregroundStyle(PopoverPalette.secondary)
                Button("Log in") {
                    startSignIn()
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(PopoverPalette.brandText)
                Text("·")
                    .foregroundStyle(PopoverPalette.secondary)
                Button("Sign up") {
                    if let url = URL(string: "\(Constants.appURL)/auth/signup") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(PopoverPalette.brandText)
            }
            .font(BrandFonts.sans(13, weight: .medium))
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.sideMargin)
    }

    private var signingInView: some View {
        VStack(spacing: 0) {
            Spacer()
            GarryOnHisLine(walking: true, scale: 1)
                .padding(.bottom, 20)
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 12)
            Text("Signing in\u{2026}")
                .font(BrandFonts.sans(17, weight: .semibold))
            Text("Finish in your browser, then come back here.")
                .font(BrandFonts.sans(13.5))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func instancePickerView(instances: [Instance]) -> some View {
        GuidePage(title: "Used LobsterOne before?",
                  detail: "Link this Mac to an earlier instance to keep its leaderboard history together, or start fresh.") {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(instances.enumerated()), id: \.element.id) { index, instance in
                        if index > 0 { GuideDivider() }
                        instanceRow(instance)
                    }
                }
                .background(PopoverPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 250)
        }
    }

    private func instanceRow(_ instance: Instance) -> some View {
        let chosen = linkTo == instance.id
        return Button { linkTo = instance.id } label: {
            HStack(spacing: 12) {
                ZStack {
                    if chosen {
                        Circle().strokeBorder(PopoverPalette.brand, lineWidth: 5)
                    } else {
                        Circle().fill(PopoverPalette.background)
                        Circle().strokeBorder(PopoverPalette.lineStrong, lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.displayName)
                        .font(BrandFonts.sans(14, weight: .semibold))
                    if let sourceType = instance.sourceType {
                        Text(sourceType)
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.secondary)
                    }
                }
                Spacer()
                if instance.isActive {
                    // Success carries a tick, never colour alone.
                    HStack(spacing: 3) {
                        LineGlyph(data: HorizonGlyphs.check, size: 12, lineWidth: 2.4)
                        Text("active")
                    }
                    .font(BrandFonts.sans(12, weight: .medium))
                    .foregroundStyle(PopoverPalette.successText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PopoverPalette.successBackground, in: Capsule())
                } else {
                    Text(instance.orphaned == true ? "orphaned" : "revoked")
                        .font(BrandFonts.sans(12, weight: .medium))
                        .foregroundStyle(PopoverPalette.warningText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(PopoverPalette.warningBackground, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func completeView(email: String, planTier: String) -> some View {
        VStack(spacing: 0) {
            Spacer()

            LineGlyph(data: HorizonGlyphs.check, size: 22, lineWidth: 2.2)
                .foregroundStyle(PopoverPalette.successText)
                .frame(width: 44, height: 44)
                .background(PopoverPalette.successBackground, in: Circle())
                .padding(.bottom, 14)

            Text("You're all set")
                .font(BrandFonts.sans(22, weight: .semibold))
                .tracking(-0.03 * 22)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 2) {
                Text(email)
                Text("\(QuotaState.tierLabel(for: planTier)) plan")
            }
            .font(BrandFonts.sans(13.5))
            .foregroundStyle(PopoverPalette.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            LineGlyph(data: HorizonGlyphs.warning, size: 22, lineWidth: 2)
                .foregroundStyle(PopoverPalette.criticalText)
                .frame(width: 44, height: 44)
                .background(PopoverPalette.criticalBackground, in: Circle())

            Text("Something went wrong")
                .font(BrandFonts.sans(22, weight: .semibold))
                .tracking(-0.03 * 22)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(BrandFonts.sans(13.5))
                .foregroundStyle(PopoverPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sign-in

    private func startSignIn() {
        step = .signingIn
        Task {
            do {
                let authResult = try await authService.signIn()

                let apiKeyResponse = try await authService.createAPIKeyWithRetry(
                    apiClient: apiClient,
                    idToken: authResult.idToken
                )

                // Fetch existing instances to offer linking
                let instances: [Instance]
                do {
                    let allInstances = try await apiClient.fetchInstances(bearerToken: authResult.idToken)
                    // Show all instances except the one we just created
                    instances = allInstances.filter { $0.id != apiKeyResponse.id }
                } catch {
                    instances = []
                }

                if instances.isEmpty {
                    // No existing instances — go straight to completion
                    finishSetup(newKey: apiKeyResponse, idToken: authResult.idToken, refreshToken: authResult.refreshToken, email: authResult.email)
                } else {
                    // Show instance picker
                    linkTo = nil
                    step = .pickInstance(
                        instances: instances,
                        newKeyResponse: apiKeyResponse,
                        idToken: authResult.idToken,
                        refreshToken: authResult.refreshToken,
                        email: authResult.email
                    )
                }
            } catch AuthError.cancelled {
                step = .welcome
            } catch {
                step = .error(message: error.localizedDescription)
            }
        }
    }

    private func linkToInstance(instance: Instance, newKey: CreateAPIKeyResponse, idToken: String, refreshToken: String, email: String?) {
        step = .signingIn // Show spinner while merging
        Task {
            do {
                // Merge the old instance into the new key
                // This auto-revokes the old instance and links its historical data to the new key
                try await apiClient.mergeInstance(
                    sourceId: instance.id,
                    targetId: newKey.id,
                    bearerToken: idToken
                )

                // Inherit the old instance's label on the new key
                if let label = instance.label {
                    try? await apiClient.renameInstance(
                        id: newKey.id,
                        label: label,
                        bearerToken: idToken
                    )
                }

                finishSetup(newKey: newKey, idToken: idToken, refreshToken: refreshToken, email: email)
            } catch {
                // Merge failed — continue without merging rather than blocking setup
                DebugLog.shared.log("Instance merge failed: \(error). Continuing without merge.")
                finishSetup(newKey: newKey, idToken: idToken, refreshToken: refreshToken, email: email)
            }
        }
    }

    private func finishSetup(newKey: CreateAPIKeyResponse, idToken: String, refreshToken: String, email: String?) {
        Task {
            do {
                let keychain = KeychainService()
                try keychain.saveAPIKey(newKey.key)
                try keychain.saveAPIKeyId(newKey.id)
                try keychain.saveTokens(idToken: idToken, refreshToken: refreshToken)

                let configService = ConfigService()
                try configService.writeConfig(apiKey: newKey.key)

                // Configure Codex in the same setup flow so failures are surfaced.
                if configService.isCodexInstalled() && !configService.isCodexConfigured() {
                    let codexKey = try await authService.createAPIKeyWithRetry(
                        apiClient: apiClient,
                        idToken: idToken,
                        label: "LobsterOne Mac App — Codex",
                        sourceType: "codex"
                    )
                    try configService.writeCodexConfig(apiKey: codexKey.key)
                    DebugLog.shared.log("Codex detected — configured telemetry with key \(codexKey.keyPrefix)...")
                }

                apiClient.setAPIKey(newKey.key)
                let quota = try await apiClient.fetchQuota()

                onSignedIn()
                // A Mac set up before, or one that has seen the guide, goes straight to work.
                if SetupGuide.shouldShowAfterSignIn(guide.env.defaults) {
                    guide.begin()
                } else {
                    step = .complete(
                        email: email ?? "Unknown",
                        planTier: quota.planTier
                    )
                }
            } catch {
                step = .error(message: error.localizedDescription)
            }
        }
    }
}

/// One dot per step: the current one a short Lobster bar, the rest quiet.
struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? PopoverPalette.brand
                          : index < current ? PopoverPalette.bar : PopoverPalette.track)
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
