import AppKit
import SwiftUI

/// Settings › AWS: connect a profile or pasted keys, choose what shows in the menu bar, and
/// set per-account alerts. Keys go to the Keychain and are never shown again once saved.
struct AWSSettingsPane: View {
    @ObservedObject var service: AWSCostService
    @ObservedObject var monitor: CostMonitor
    var openNotifications: () -> Void = {}

    @State private var profiles: [AWSCostService.Profile] = []
    @State private var addingKeys = false
    @State private var keyId = ""
    @State private var secret = ""
    @State private var checkingKeys = false
    @State private var keysError: String?
    @State private var copiedCommand: String?
    @State private var copiedPolicy = false
    @State private var editingAlert: String?

    /// Read-only: the cost figures and the account names, nothing else.
    static let policy = #"{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ce:GetCostAndUsage","organizations:ListAccounts"],"Resource":"*"}]}"#

    private static let policyDisplay = """
    {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Action": ["ce:GetCostAndUsage", "organizations:ListAccounts"],
        "Resource": "*"
      }]
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !service.isConnected { intro }
            loginsSection
            if service.isConnected {
                menuBarSection
                alertsSection
            }
            leastAccessSection
        }
        .onAppear { profiles = service.profiles }
        // Free STS calls, so every row can say whether its login works before one is chosen.
        .task {
            await service.checkProfiles()
            // Pasted keys have no profile to check, so ask once which account they belong to.
            await service.refreshIdentities()
        }
    }

    // MARK: - Intro

    private var intro: some View {
        HStack(alignment: .center, spacing: 14) {
            GarrySprite(walking: false, scale: 0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your AWS bill, next to your Claude usage")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text("This month's spend per account, read from AWS Cost Explorer. Keys and figures stay on this Mac. AWS bills $0.01 a refresh: once a day, and when you open the AWS page, at most hourly.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Logins

    /// One row per way of signing in, each saying where it stands: connected, ready to
    /// connect, or what it needs first. Only one is connected at a time.
    private var loginsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section(service.isConnected ? "Logins" : "Connect") {
                VStack(spacing: 0) {
                    if profiles.isEmpty {
                        Text("No AWS profiles found in ~/.aws on this Mac.")
                            .font(BrandFonts.sans(12.5))
                            .foregroundStyle(PopoverPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                        divider
                    }
                    ForEach(profiles) { profile in
                        profileRow(profile)
                        divider
                    }
                    ForEach(missingProfiles, id: \.self) { name in
                        missingProfileRow(name)
                        divider
                    }
                    keysRow
                    if addingKeys && !service.isConnected(.accessKeys) { keyFields }
                    if service.isConnected {
                        divider
                        figuresRow
                    }
                }
            }
            Text("Checking a login is free. Connect one that sees all accounts, or add several and their accounts are shown together and totalled. Each connected login costs $0.01 a refresh.")
                .font(BrandFonts.sans(12))
                .foregroundStyle(PopoverPalette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    /// Connected profiles that are no longer in ~/.aws, so they can still be removed.
    private var missingProfiles: [String] {
        service.connections.compactMap { connection in
            if case .profile(let name) = connection, !profiles.contains(where: { $0.name == name }) { return name }
            return nil
        }
    }

    private func missingProfileRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(BrandFonts.mono(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Chip(text: "Connected", tone: .success)
            Spacer(minLength: 8)
            Text("No longer in ~/.aws")
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.warningText)
            DisconnectButton(title: "Remove") { service.disconnect(.profile(name: name)) }
                .accessibilityLabel("Remove \(name)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
    }

    private func profileRow(_ profile: AWSCostService.Profile) -> some View {
        let connected = service.isConnected(.profile(name: profile.name))
        let check = service.checks[profile.name]
        return HStack(spacing: 8) {
            Text(profile.name)
                .font(BrandFonts.mono(13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Chip(text: profile.kindLabel, quiet: true)
                .help(profile.usesCLI ? "Signs in through the aws CLI" : "Keys from ~/.aws/credentials")
            if connected { Chip(text: "Connected", tone: .success) }
            Spacer(minLength: 8)
            statusLabel(check, connection: connected ? .profile(name: profile.name) : nil)
            profileAction(profile, check: check, connected: connected)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
    }

    /// What the free check said, in a few words. The row's button says what to do about it.
    @ViewBuilder
    private func statusLabel(_ check: AWSCostService.LoginCheck?, connection: AWSConnection?) -> some View {
        Group {
            if let connection, let other = service.coveredBy(connection) {
                // Connected, but another login already returns the same accounts.
                Text("Covered by \(AWSCostService.label(other))")
                    .foregroundStyle(PopoverPalette.tertiary)
                    .help("Removing this login saves a request and changes nothing in the list")
            } else {
            switch check {
            case nil:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking\u{2026}").foregroundStyle(PopoverPalette.secondary)
                }
            case .ready(let who):
                Text(Self.scopeText(who))
                    .foregroundStyle(who.scope == .oneAccount ? PopoverPalette.tertiary : PopoverPalette.secondary)
                    .textSelection(.enabled)
                    .help(who.arn)
            case .failed(let error):
                Text(Self.shortReason(error))
                    .foregroundStyle(PopoverPalette.warningText)
                    .help(CostErrorCopy.describe(error).detail)
            }
            }
        }
        .font(BrandFonts.sans(12.5))
        .lineLimit(1)
    }

    @ViewBuilder
    private func profileAction(_ profile: AWSCostService.Profile, check: AWSCostService.LoginCheck?,
                               connected: Bool) -> some View {
        switch check {
        case .failed(.needsSignIn(let named)):
            let command = CostErrorCopy.signInCommand(profile: named ?? profile.name)
            RowButton(title: copiedCommand == command ? "Copied" : "Copy sign-in command") { copy(command) }
                .help("Run \(command) in Terminal, then check again")
            RowButton(title: "Check again") { recheck(profile.name) }
        case .failed(.cliMissing):
            RowButton(title: "Install the aws CLI") { NSWorkspace.shared.open(CostLinks.installCLI) }
        case .failed:
            RowButton(title: "Check again") { recheck(profile.name) }
        case .ready where !connected:
            RowButton(title: service.isConnected ? "Add" : "Connect",
                      prominent: isBestChoice(who(check))) {
                service.connect(.profile(name: profile.name))
            }
        case .checking, .ready, nil:
            EmptyView()
        }
        if connected {
            // A profile is only a pointer; removing it deletes nothing and it can be added back.
            DisconnectButton(title: "Remove") { service.disconnect(.profile(name: profile.name)) }
                .accessibilityLabel("Remove \(profile.name)")
        }
    }

    /// What a working login can read, which is what decides which one to connect.
    private static func scopeText(_ who: AWSIdentity) -> String {
        switch who.scope {
        case .allAccounts: "Sees all accounts · \(who.account)"
        case .oneAccount: "One account only · \(who.account)"
        case .unknown: "Signed in · account \(who.account)"
        }
    }

    private func who(_ check: AWSCostService.LoginCheck?) -> AWSIdentity? {
        if case .ready(let who) = check { return who }
        return nil
    }

    /// The filled button goes to the login worth choosing: one that sees all accounts when
    /// nothing connected does; otherwise any, until something is connected.
    private func isBestChoice(_ who: AWSIdentity?) -> Bool {
        if service.isConnected {
            return who?.scope == .allAccounts
                && !service.identities.values.contains { $0.scope == .allAccounts }
        }
        return who?.scope != .oneAccount || !anyLoginSeesAll
    }

    /// When one login sees everything, it alone gets the filled Connect button.
    private var anyLoginSeesAll: Bool {
        service.checks.values.contains { who($0)?.scope == .allAccounts }
    }

    private static func shortReason(_ error: CostError) -> String {
        switch error {
        case .needsSignIn: "Sign in needed"
        case .cliMissing: "Needs the aws CLI"
        case .credentialsInvalid: "Keys not accepted"
        case .network: "Couldn't reach AWS"
        case .accessDenied: "Access denied"
        case .notConnected: "No login in this profile"
        case .notEnabled, .other: "Couldn't sign in"
        }
    }

    private func recheck(_ name: String) {
        Task { await service.check(name) }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommand = command
    }

    private var keysRow: some View {
        let connected = service.isConnected(.accessKeys)
        return HStack(spacing: 8) {
            Text(connected ? "Access keys" : "Paste access keys")
                .font(BrandFonts.sans(14, weight: .semibold))
            if connected { Chip(text: "Connected", tone: .success) }
            Spacer(minLength: 8)
            if connected {
                if let account = service.identities[.accessKeys]?.account {
                    Text("Account \(account)")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .textSelection(.enabled)
                }
                DisconnectButton(title: "Remove") { confirmRemoveKeys() }
                    .accessibilityLabel("Remove access keys")
            } else {
                Text("Saved in your Keychain, not in ~/.aws")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                RowButton(title: addingKeys ? "Cancel" : "Add keys") {
                    addingKeys.toggle()
                    keysError = nil
                    if !addingKeys { keyId = ""; secret = "" }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 42)
    }

    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Access key ID", text: $keyId)
                .textFieldStyle(.roundedBorder)
                .font(BrandFonts.mono(12.5))
                .autocorrectionDisabled()
            SecureField("Secret access key", text: $secret)
                .textFieldStyle(.roundedBorder)
                .font(BrandFonts.mono(12.5))
            HStack(spacing: 10) {
                Group {
                    if checkingKeys {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking\u{2026}").foregroundStyle(PopoverPalette.secondary)
                        }
                    } else if let keysError {
                        Text(keysError).foregroundStyle(PopoverPalette.criticalText)
                    }
                }
                .font(BrandFonts.sans(12.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                RowButton(title: service.isConnected ? "Add" : "Connect", prominent: true) { connectKeys() }
                    .disabled(checkingKeys || !canSubmitKeys)
                    .opacity(canSubmitKeys ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var canSubmitKeys: Bool {
        AWSCostService.cleanKeys(id: keyId, secret: secret) != nil
    }

    /// Checks the pasted keys with the free call first, so keys AWS rejects are never saved.
    private func connectKeys() {
        let id = keyId, secret = secret
        checkingKeys = true
        keysError = nil
        Task {
            defer { checkingKeys = false }
            if case .failure(let error) = await service.testConnection(.accessKeys(id: id, secret: secret)) {
                let info = CostErrorCopy.describe(error)
                keysError = "\(info.title). \(info.detail)"
                return
            }
            do {
                try service.connectWithAccessKeys(id: id, secret: secret)
            } catch let error as AWSKeysError {
                keysError = error.message
                return
            } catch {
                keysError = "Couldn't save the keys in your Keychain."
                return
            }
            // The secret lives in the Keychain now; nothing on screen holds it.
            self.keyId = ""
            self.secret = ""
            addingKeys = false
        }
    }

    /// Under the logins once one is connected: how fresh the figures are, and anything wrong
    /// with fetching them.
    private var figuresRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(monitor.error == nil ? PopoverPalette.dotActive : PopoverPalette.dotWaiting)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(figuresText)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                Spacer(minLength: 8)
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                RowButton(title: "Refresh now") {
                    Task { await monitor.refresh(ifOlderThan: AWSCostService.manualRefreshInterval) }
                }
                .disabled(monitor.isRefreshing || refreshedRecently)
                .opacity(refreshedRecently ? 0.5 : 1)
                .help(refreshedRecently ? "Refreshed in the last five minutes" : "Fetch the latest figures ($0.01 on your AWS bill)")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 42)

            if let error = monitor.error {
                divider
                let info = CostErrorCopy.describe(error)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).font(BrandFonts.sans(13.5, weight: .semibold))
                    Text(info.detail).font(BrandFonts.sans(12.5)).fixedSize(horizontal: false, vertical: true)
                    if let command = info.command {
                        Text(command).font(BrandFonts.mono(12)).textSelection(.enabled).padding(.top, 4)
                    }
                }
                .foregroundStyle(PopoverPalette.warningText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(PopoverPalette.warningBackground)
            }
        }
    }

    private var figuresText: String {
        if let snapshot = monitor.snapshot {
            return AWSCostsView.updatedText(snapshot.fetchedAt, now: Date())
        }
        return monitor.isRefreshing ? "Fetching the first figures" : "No figures yet"
    }

    /// Asks first, like disconnecting a tool: pasted keys are deleted and can't be brought back.
    private func confirmRemoveKeys() {
        let alert = NSAlert()
        alert.messageText = "Remove the access keys?"
        alert.informativeText = "This deletes the keys saved on this Mac, and their accounts leave the list. Your alert amounts are kept."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.disconnect(.accessKeys)
    }

    private var refreshedRecently: Bool {
        guard let fetched = monitor.snapshot?.fetchedAt else { return false }
        return Date().timeIntervalSince(fetched) < AWSCostService.manualRefreshInterval
    }

    private var menuBarSection: some View {
        section("Menu bar") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show this month's total in the menu bar")
                        .font(BrandFonts.sans(14.5, weight: .semibold))
                    Text("Adds it after your usage, like \u{00B7} $413.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                Spacer(minLength: 0)
                Toggle("Show this month's total in the menu bar", isOn: $service.showsTotalInMenuBar)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(PopoverPalette.brand)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Alerts") {
                VStack(spacing: 0) {
                    Text("Get a Mac notification the first time an account passes its amount in a month.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    let accounts = monitor.accounts
                    if accounts.isEmpty {
                        divider
                        Text("Accounts show here after the first refresh.")
                            .font(BrandFonts.sans(13.5))
                            .foregroundStyle(PopoverPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    ForEach(accounts) { account in
                        divider
                        alertRow(account)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Cost alerts can be switched off in")
                    .foregroundStyle(PopoverPalette.tertiary)
                Button("Notifications") { openNotifications() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(PopoverPalette.brandText)
            }
            .font(BrandFonts.sans(12))
            .padding(.leading, 2)
        }
    }

    private func alertRow(_ account: AccountCost) -> some View {
        let limit = monitor.alertLimits[account.id]
        let currency = monitor.snapshot?.currency
        let over = limit.map { account.thisMonth > $0 } ?? false
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AccountCostRow.title(account))
                    .font(BrandFonts.sans(14, weight: .semibold))
                    .lineLimit(1)
                Text("\(account.accountId) \u{00B7} \(CostFormat.money(account.thisMonth, currency: currency)) so far")
                    .font(BrandFonts.sans(12))
                    .foregroundStyle(PopoverPalette.tertiary)
            }
            Spacer(minLength: 8)
            if let limit {
                Text(CostFormat.money(limit, currency: currency))
                    .font(BrandFonts.sans(14, weight: .semibold))
                    .foregroundStyle(over ? PopoverPalette.criticalText : PopoverPalette.text)
                    .help(over ? "Over its alert amount this month" : "Alert amount per month")
            } else {
                Text("No alert")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.tertiary)
            }
            SettingsPill(title: limit == nil ? "Set" : "Change", prominent: false) { editingAlert = account.id }
                .accessibilityLabel("\(limit == nil ? "Set an alert" : "Change the alert") for \(AccountCostRow.title(account))")
                .popover(isPresented: Binding(get: { editingAlert == account.id },
                                              set: { if !$0 { editingAlert = nil } }),
                         arrowEdge: .bottom) {
                    CostAlertEditor(name: AccountCostRow.title(account), current: limit, currency: currency) { value in
                        monitor.setAlertLimit(value, for: account.id)
                        editingAlert = nil
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Least access

    private var leastAccessSection: some View {
        section("Least access") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use an IAM user or role made only for this, with read-only billing access. It needs just these two permissions:")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.policyDisplay)
                    .font(BrandFonts.mono(11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    SettingsPill(title: copiedPolicy ? "Copied" : "Copy policy", prominent: false) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.policy, forType: .string)
                        copiedPolicy = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedPolicy = false
                        }
                    }
                    .accessibilityLabel("Copy the IAM policy")
                    SettingsPill(title: "Open AWS Billing", prominent: false) {
                        NSWorkspace.shared.open(CostLinks.billing)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    /// A sentence-case label over a Sand card, as the other tabs have.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .medium))
                .foregroundStyle(PopoverPalette.secondary)
                .padding(.leading, 2)
            content()
                .background(PopoverPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var divider: some View {
        Rectangle().fill(PopoverPalette.divider).frame(height: 1)
    }
}

/// A pill sized for a list row, so a row with a button stays one line tall.
private struct RowButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(12.5, weight: .semibold))
                .foregroundStyle(prominent ? PopoverPalette.onBrand : PopoverPalette.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(prominent ? (hovering ? PopoverPalette.primaryHover : PopoverPalette.brand)
                                      : (hovering ? PopoverPalette.hover : PopoverPalette.background), in: Capsule())
                .overlay(Capsule().strokeBorder(prominent ? Color.clear : PopoverPalette.lineStrong))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
