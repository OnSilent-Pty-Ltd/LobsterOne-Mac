import Foundation

nonisolated enum CostLinks {
    static let billing = URL(string: "https://console.aws.amazon.com/billing/home")!
    static let costExplorer = URL(string: "https://console.aws.amazon.com/cost-management/home#/cost-explorer")!
    static let iamBillingAccess = URL(string: "https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/control-access-billing.html#ControllingAccessWebsite-Activate")!
    static let installCLI = URL(string: "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html")!
}

nonisolated enum CostFormat {
    static func money(_ amount: Double, currency: String?) -> String {
        format(amount, currency: currency, fraction: 2)
    }

    /// Compact for the menu bar: no cents once it's $100 or more.
    static func short(_ amount: Double, currency: String?) -> String {
        format(amount, currency: currency, fraction: amount >= 100 ? 0 : 2)
    }

    /// AWS bills in US dollars and shows them as "$12.50". Some locales would
    /// print "USD 12.50", so USD always uses the US style.
    private static func format(_ amount: Double, currency: String?, fraction: Int) -> String {
        let code = currency ?? "USD"
        let style = FloatingPointFormatStyle<Double>.Currency(code: code)
            .precision(.fractionLength(fraction))
        return amount.formatted(code == "USD" ? style.locale(Locale(identifier: "en_US")) : style)
    }

    /// A change in words: 0.7 reads "Up 70%", -0.18 reads "Down 18%".
    static func direction(_ change: Double) -> String {
        let amount = percent(change)
        if amount == "0%" { return "No change" }
        return (change > 0 ? "Up " : "Down ") + amount
    }

    /// A change as a whole percentage without its sign: -0.18 reads "18%".
    static func percent(_ change: Double) -> String {
        let value = (abs(change) * 100).rounded()
        return value > 999 ? "999%+" : "\(Int(value))%"
    }

    /// The name of a "YYYY-MM" month, or of the month `offset` months away.
    static func monthName(_ month: String, offset: Int = 0, short: Bool = false,
                          locale: Locale = .current) -> String? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        let index = ((parts[1] - 1 + offset) % 12 + 12) % 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = short ? calendar.shortStandaloneMonthSymbols : calendar.standaloneMonthSymbols
        return names.indices.contains(index) ? names[index] : nil
    }
}

/// Plain-language wording for each cost error, with the one thing to do next.
nonisolated enum CostErrorCopy {
    enum Target: Equatable, Sendable { case url(URL), openSettings }
    struct Action: Equatable, Sendable { let title: String; let target: Target }
    struct Info: Equatable, Sendable {
        let title: String
        let detail: String
        let action: Action?
        /// A Terminal command the person has to run themselves, for a copy button.
        var command: String? = nil
    }

    static func describe(_ error: CostError) -> Info {
        let settings = Action(title: "Open Settings", target: .openSettings)
        switch error {
        case .notConnected:
            return Info(title: "Connect AWS to see costs",
                        detail: "Add an AWS profile or access key in Settings and your monthly spend will show here.",
                        action: settings)
        case .needsSignIn(let profile):
            let command = signInCommand(profile: profile)
            return Info(title: "Your AWS sign-in has expired",
                        detail: "Run \(command) in Terminal, then refresh. LobsterOne won't open the browser to sign you in on its own.",
                        action: nil, command: command)
        case .cliMissing:
            return Info(title: "This profile needs the AWS CLI",
                        detail: "Your AWS profile signs in through the aws command, which isn't installed on this Mac. Install it, or use an access key in Settings instead.",
                        action: Action(title: "How to install it", target: .url(CostLinks.installCLI)))
        case .notEnabled:
            return Info(title: "Turn on AWS Cost Explorer",
                        detail: "AWS needs Cost Explorer switched on once, in your main account. Open it and the first numbers arrive within 24 hours.",
                        action: Action(title: "Open Cost Explorer", target: .url(CostLinks.costExplorer)))
        case .accessDenied:
            return Info(title: "AWS won't share billing data yet",
                        detail: "Your AWS user isn't allowed to read costs. Signed in as the account owner, turn on \"IAM user and role access to Billing information\" in Account settings.",
                        action: Action(title: "How to turn it on", target: .url(CostLinks.iamBillingAccess)))
        case .credentialsInvalid:
            return Info(title: "AWS didn't accept these keys",
                        detail: "The access key may have been deleted or mistyped. Check it in Settings.",
                        action: settings)
        case .network:
            return Info(title: "Couldn't reach AWS",
                        detail: "Check your internet connection. Costs will update next time you open this.",
                        action: nil)
        case .other(let message):
            return Info(title: "Couldn't load costs", detail: message, action: nil)
        }
    }

    /// `aws sso login`, with the profile quoted when it has characters a shell would read.
    static func signInCommand(profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return "aws sso login" }
        let safe = profile.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@+".contains($0)) }
        let quoted = safe ? profile : "'" + profile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "aws sso login --profile \(quoted)"
    }
}
