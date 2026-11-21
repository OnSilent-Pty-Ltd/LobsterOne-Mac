import AppKit
import SwiftUI

/// Which page the popover shows between its header and footer. Remembered across launches.
enum PopoverPage: String {
    case claude, team, aws

    var title: String {
        switch self {
        case .claude: "Code"
        case .team: "Agents"
        case .aws: "Infra"
        }
    }
}

extension HorizonGlyphs {
    static let bell = "M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15ZM10 20.5a2 2 0 0 0 4 0"
    static let chevronDown = "M7.5 10l4.5 4.5 4.5-4.5"
    static let copy = "M9 10.5A1.5 1.5 0 0 1 10.5 9h7A1.5 1.5 0 0 1 19 10.5v7a1.5 1.5 0 0 1-1.5 1.5h-7A1.5 1.5 0 0 1 9 17.5ZM5 14.5v-8A1.5 1.5 0 0 1 6.5 5h8"
}

/// "Code | Agents | Infra", under the popover header once there is more than one page to show.
/// Shortcuts follow the order shown: ⌘1 for the first page, ⌘2 for the next.
struct PopoverPageSwitch: View {
    @Binding var page: PopoverPage
    let pages: [PopoverPage]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(pages.enumerated()), id: \.element) { index, value in
                segment(value.title, value, shortcut: index + 1)
            }
        }
        .padding(3)
        .background(PopoverPalette.card, in: Capsule())
    }

    private func segment(_ title: String, _ value: PopoverPage, shortcut: Int) -> some View {
        let selected = page == value
        return Button { page = value } label: {
            Text(title)
                .font(BrandFonts.sans(13, weight: .semibold))
                .foregroundStyle(selected ? PopoverPalette.onBrand : PopoverPalette.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(selected ? PopoverPalette.brand : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌘\(shortcut))")
        .accessibilityLabel("\(title) page")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The popover's AWS page: this month's bill and each account. Reads only
/// what `CostMonitor` already has; opening it asks for fresh figures at most hourly.
struct AWSCostsView: View {
    @ObservedObject var monitor: CostMonitor
    let now: Date
    let perform: (StatusBarController.PopoverAction) -> Void
    /// Set when the list may not be the whole bill: a login couldn't be read, or the one
    /// connected login sees a single account.
    var note: String?
    /// How many logins a refresh reads through; each is one billed request.
    @State private var expandedID: String?
    @State private var copiedCommand = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hPad: CGFloat = 16

    init(monitor: CostMonitor, now: Date, perform: @escaping (StatusBarController.PopoverAction) -> Void,
         expandedID: String? = nil, note: String? = nil) {
        self.note = note
        self.monitor = monitor
        self.now = now
        self.perform = perform
        self._expandedID = State(initialValue: expandedID)
    }

    var body: some View {
        let accounts = monitor.accounts
        VStack(alignment: .leading, spacing: 12) {
            totalCard(accounts)
            if let error = monitor.error {
                errorBox(error)
            } else if let note {
                scopeNote(note)
            }
            if !accounts.isEmpty {
                accountList(accounts)
            } else if monitor.error == nil {
                emptyLine
            }
            caption
        }
    }

    // MARK: - Months

    private var month: String { CostMath.month(now) }
    private var monthName: String { CostFormat.monthName(month) ?? "This month" }
    private var lastMonthName: String { CostFormat.monthName(month, offset: -1) ?? "Last month" }
    private var lastMonthShortName: String { CostFormat.monthName(month, offset: -1, short: true) ?? "last month" }
    private var currency: String? { monitor.snapshot?.currency }

    private func money(_ amount: Double) -> String { CostFormat.money(amount, currency: currency) }

    // MARK: - Total

    private var totalTrend: SpendTrend? {
        guard let total = monitor.monthToDateTotal else { return nil }
        return SpendTrend(thisMonth: total, lastMonth: monitor.lastMonthTotal ?? 0, forecast: monitor.forecastTotal)
    }

    private func scopeNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.warningText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings") { perform(.awsSettings) }
                .buttonStyle(.plain)
                .font(BrandFonts.sans(12.5, weight: .semibold))
                .foregroundStyle(PopoverPalette.warningText)
                .underline()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(PopoverPalette.warningBackground, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, hPad)
    }

    private func totalCard(_ accounts: [AccountCost]) -> some View {
        let trend = totalTrend
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(accounts.count == 1 ? "AWS" : "\(accounts.count) accounts") · \(monthName)")
                    .font(BrandFonts.sans(14))
                    .foregroundStyle(PopoverPalette.secondary)
                Spacer(minLength: 4)
                if monitor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Refreshing")
                }
            }
            .frame(height: 18)

            HStack(alignment: .center, spacing: 10) {
                Text(monitor.monthToDateTotal.map(money) ?? "\u{2013}")
                    .font(BrandFonts.sans(25, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let trend, let change = trend.change {
                    CostTrendPill(change: change, rising: trend.isRising, suffix: " vs \(lastMonthShortName)")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            if let trend {
                CostSpendBar(trend: trend, height: 8)
                    .padding(.top, 12)
                HStack(spacing: 8) {
                    if let forecast = trend.forecast {
                        Text("On pace for ") + Text(money(forecast)).fontWeight(.semibold).foregroundColor(PopoverPalette.text)
                    }
                    Spacer(minLength: 8)
                    if trend.lastMonth > 0 {
                        Text("\(lastMonthName) ") + Text(money(trend.lastMonth)).fontWeight(.semibold).foregroundColor(PopoverPalette.text)
                    }
                }
                .font(BrandFonts.sans(12.5))
                .foregroundStyle(PopoverPalette.secondary)
                .lineLimit(1)
                .padding(.top, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .padding(.horizontal, hPad)
    }

    // MARK: - Error

    private func errorBox(_ error: CostError) -> some View {
        let info = CostErrorCopy.describe(error)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(BrandFonts.sans(14, weight: .semibold))
                Text(info.detail)
                    .font(BrandFonts.sans(12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = info.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(BrandFonts.mono(11.5))
                        .foregroundStyle(PopoverPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedCommand = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedCommand = false
                        }
                    } label: {
                        LineGlyph(data: copiedCommand ? HorizonGlyphs.check : HorizonGlyphs.copy, size: 14, lineWidth: 2)
                            .foregroundStyle(copiedCommand ? PopoverPalette.successText : PopoverPalette.text)
                            .frame(width: 26, height: 26)
                            .background(PopoverPalette.warningBackground, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(copiedCommand ? "Copied" : "Copy the command")
                    .accessibilityLabel(copiedCommand ? "Copied" : "Copy the command")
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .frame(minHeight: 32)
                .background(PopoverPalette.background, in: RoundedRectangle(cornerRadius: 8))
            }
            if let action = info.action {
                Button {
                    switch action.target {
                    case .openSettings: perform(.awsSettings)
                    case .url(let url): perform(.openURL(url))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(action.title)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(BrandFonts.sans(13, weight: .semibold))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(PopoverPalette.warningText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PopoverPalette.warningBackground, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, hPad)
    }

    // MARK: - Accounts

    /// Tall enough for about six rows and one open, shorter on small displays.
    private var listMaxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(440, max(220, screen - 420))
    }

    private func accountList(_ accounts: [AccountCost]) -> some View {
        let context = AccountCostRow.Context(
            currency: currency, lastMonthName: lastMonthName, lastMonthShortName: lastMonthShortName,
            daysInMonth: CostMath.days(inMonth: month), total: monitor.monthToDateTotal)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }
                    AccountCostRow(account: account, context: context,
                                   alertLimit: monitor.alertLimits[account.id],
                                   setAlertLimit: { monitor.setAlertLimit($0, for: account.id) },
                                   isExpanded: expandedID == account.id,
                                   toggle: { toggle(account.id) },
                                   openBilling: { perform(.openURL(CostLinks.billing)) })
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: listMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(PopoverPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, hPad)
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            expandedID = expandedID == id ? nil : id
        }
    }

    private var emptyLine: some View {
        Text(monitor.isRefreshing || monitor.snapshot == nil
             ? "Fetching this month's costs\u{2026}"
             : "No AWS spend recorded this month yet.")
            .font(BrandFonts.sans(13.5))
            .foregroundStyle(PopoverPalette.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, hPad)
    }

    // MARK: - Caption

    private var caption: some View {
        Text(monitor.snapshot.map { Self.updatedText($0.fetchedAt, now: now) } ?? "")
            .font(BrandFonts.sans(12))
            .foregroundStyle(PopoverPalette.tertiary)
            .padding(.horizontal, hPad)
    }

    static func updatedText(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date))) / 60
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes)m ago" }
        if minutes < 48 * 60 { return "Updated \(minutes / 60)h ago" }
        return "Updated \(minutes / (24 * 60))d ago"
    }
}

// MARK: - Pieces

/// Spend so far, the pace to month end in a paler tone, and a tick where last month finished
/// when this month is heading past it.
struct CostSpendBar: View {
    let trend: SpendTrend
    var height: CGFloat = 8
    var spent: Color = PopoverPalette.brand

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(PopoverPalette.track)
                segment(trend.paceFraction, of: width).fill(PopoverPalette.bar)
                segment(trend.spentFraction, of: width).fill(spent)
            }
            .frame(height: height)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if let at = trend.lastMonthMark {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(PopoverPalette.text)
                        .frame(width: 2, height: height + 6)
                        .offset(x: (width * at - 1).rounded())
                }
            }
        }
        .frame(height: height + 6)
        .accessibilityHidden(true)
    }

    /// A filled length of the bar; a sliver still shows as a full round end.
    private func segment(_ fraction: Double, of width: CGFloat) -> some Shape {
        let length = fraction > 0 ? max(height, width * min(1, fraction)) : 0
        return Capsule().size(width: length, height: height)
    }
}

/// An arrow and a percentage: Blush when rising fast, green when down, quiet otherwise.
struct CostTrendPill: View {
    let change: Double
    let rising: Bool
    var suffix = ""

    static func arrow(_ change: Double) -> String {
        change > 0.005 ? "\u{2191}" : (change < -0.005 ? "\u{2193}" : "\u{2192}")
    }

    var body: some View {
        let down = change < -0.005
        Text("\(Self.arrow(change)) \(CostFormat.percent(change))\(suffix)")
            .font(BrandFonts.sans(12, weight: .semibold))
            .foregroundStyle(rising ? PopoverPalette.brandText : down ? PopoverPalette.successText : PopoverPalette.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(rising ? PopoverPalette.blush : down ? PopoverPalette.successBackground : PopoverPalette.background,
                        in: Capsule())
            .accessibilityLabel("\(CostFormat.direction(change))\(suffix)")
    }
}

/// One AWS account: its spend against last month, and on click the details and its alert.
struct AccountCostRow: View {
    struct Context {
        let currency: String?
        let lastMonthName: String
        let lastMonthShortName: String
        let daysInMonth: Int?
        let total: Double?
    }

    let account: AccountCost
    let context: Context
    let alertLimit: Double?
    let setAlertLimit: (Double?) -> Void
    let isExpanded: Bool
    let toggle: () -> Void
    let openBilling: () -> Void
    @State private var hovering = false
    @State private var editingAlert = false

    /// The Organizations name, else the start of the account id (the full id is in the details).
    static func title(_ account: AccountCost) -> String {
        account.name ?? "Account \(account.accountId.prefix(4))\u{2026}"
    }

    private var trend: SpendTrend {
        SpendTrend(thisMonth: account.thisMonth, lastMonth: account.lastMonth, forecast: account.forecast)
    }
    private var overLimit: Bool { alertLimit.map { account.thisMonth > $0 } ?? false }
    private func money(_ amount: Double) -> String { CostFormat.money(amount, currency: context.currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint(isExpanded ? "Hides details" : "Shows details")
            if isExpanded {
                details.transition(.opacity)
            }
        }
        .background(background)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if trend.isRising { return PopoverPalette.blush }
        return hovering || isExpanded ? PopoverPalette.cardHover : .clear
    }

    private var accessibilitySummary: String {
        var parts = ["\(Self.title(account)), \(money(account.thisMonth)) so far"]
        if let change = trend.change { parts.append(CostFormat.direction(change) + " on \(context.lastMonthName)") }
        if let forecast = trend.forecast { parts.append("on pace for \(money(forecast))") }
        if alertLimit != nil { parts.append(overLimit ? "over its alert" : "alert set") }
        return parts.joined(separator: ", ")
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(Self.title(account))
                        .font(BrandFonts.sans(14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if alertLimit != nil {
                        LineGlyph(data: HorizonGlyphs.bell, size: 13, lineWidth: 2)
                            .foregroundStyle(overLimit ? PopoverPalette.critical : PopoverPalette.secondary)
                    }
                    LineGlyph(data: HorizonGlyphs.chevronDown, size: 12, lineWidth: 2.2)
                        .foregroundStyle(PopoverPalette.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .opacity(hovering || isExpanded ? 1 : 0.5)
                }
                CostSpendBar(trend: trend, height: 5, spent: overLimit ? PopoverPalette.critical : PopoverPalette.brand)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(money(account.thisMonth))
                    .font(BrandFonts.sans(15, weight: .semibold))
                    .foregroundStyle(overLimit ? PopoverPalette.criticalText : PopoverPalette.text)
                HStack(spacing: 5) {
                    if let change = trend.change {
                        Text("\(CostTrendPill.arrow(change)) \(CostFormat.percent(change))")
                            .fontWeight(.semibold)
                            .foregroundStyle(trend.isRising ? PopoverPalette.brandText
                                             : change < -0.005 ? PopoverPalette.successText : PopoverPalette.secondary)
                    }
                    if let forecast = trend.forecast {
                        Text("to \(money(forecast))")
                    } else if trend.lastMonth > 0 {
                        Text("\(context.lastMonthShortName) \(money(trend.lastMonth))")
                    }
                }
                .font(BrandFonts.sans(12))
                .foregroundStyle(PopoverPalette.secondary)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: Details

    private struct Fact: Identifiable {
        let label: String
        let value: String
        var critical = false
        var id: String { label }
    }

    private var facts: [Fact] {
        var list = [
            Fact(label: "Spent so far", value: money(trend.thisMonth)),
            Fact(label: "On pace for", value: trend.forecast.map(money) ?? "Too early to say"),
            Fact(label: context.lastMonthName, value: money(trend.lastMonth)),
            Fact(label: "Heading", value: trend.change.map(CostFormat.direction) ?? "Nothing to compare"),
        ]
        if let days = context.daysInMonth, let average = trend.dailyAverage(daysInMonth: days) {
            list.append(Fact(label: "Per day", value: money(average)))
        }
        if let total = context.total, total > 0 {
            list.append(Fact(label: "Share of the bill", value: CostFormat.percent(trend.thisMonth / total)))
        }
        if let alertLimit {
            list.append(Fact(label: "Alert at", value: money(alertLimit)))
            let left = alertLimit - trend.thisMonth
            list.append(left >= 0 ? Fact(label: "Left before alert", value: money(left))
                                  : Fact(label: "Over alert by", value: money(-left), critical: true))
        }
        return list
    }

    private static let columns = [GridItem(.flexible(), spacing: 12, alignment: .leading),
                                  GridItem(.flexible(), spacing: 12, alignment: .leading)]

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fact.label)
                            .font(BrandFonts.sans(11.5))
                            .foregroundStyle(PopoverPalette.secondary)
                        Text(fact.value)
                            .font(BrandFonts.sans(13.5, weight: .semibold))
                            .foregroundStyle(fact.critical ? PopoverPalette.criticalText : PopoverPalette.text)
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
            Text("AWS account \(account.accountId)")
                .font(BrandFonts.mono(11.5))
                .foregroundStyle(PopoverPalette.tertiary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                RowAction(title: alertLimit == nil ? "Set an alert" : "Change alert", glyph: HorizonGlyphs.bell) {
                    editingAlert = true
                }
                .popover(isPresented: $editingAlert, arrowEdge: .bottom) {
                    CostAlertEditor(name: Self.title(account), current: alertLimit, currency: context.currency) { value in
                        setAlertLimit(value)
                        editingAlert = false
                    }
                }
                RowAction(title: "Open in AWS Billing", glyph: HorizonGlyphs.openExternal, action: openBilling)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }
}

/// A small capsule button inside an open row.
struct RowAction: View {
    let title: String
    let glyph: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LineGlyph(data: glyph, size: 13, lineWidth: 2)
                Text(title).font(BrandFonts.sans(12.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(PopoverPalette.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .fixedSize()
            .background(hovering ? PopoverPalette.hover : PopoverPalette.background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Alert me when <account> passes $X this month." Used by the popover and Settings.
struct CostAlertEditor: View {
    let name: String
    let current: Double?
    let currency: String?
    let onDone: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var amount: Double? { CostAlerts.parseAmount(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Alert me about \(name)")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                    .lineLimit(2)
                Text("A Mac notification the first time its AWS spend passes this amount in a month.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(currencySymbol)
                    .font(BrandFonts.sans(15, weight: .semibold))
                TextField("50", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(BrandFonts.sans(14))
                    .frame(width: 110)
                    .focused($focused)
                    .onSubmit { if let amount { onDone(amount) } }
                    .accessibilityLabel("Alert amount")
                Text("per month")
                    .font(BrandFonts.sans(13))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            HStack(spacing: 10) {
                if current != nil {
                    Button("Remove alert") { onDone(nil) }
                        .buttonStyle(.plain)
                        .font(BrandFonts.sans(13, weight: .semibold))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                Spacer()
                Button { if let amount { onDone(amount) } } label: {
                    Text("Save")
                        .font(BrandFonts.sans(13, weight: .semibold))
                        .foregroundStyle(PopoverPalette.onBrand)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(PopoverPalette.brand, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(amount == nil)
                .opacity(amount == nil ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .foregroundStyle(PopoverPalette.text)
        .onAppear {
            if let current { text = String(format: current == current.rounded() ? "%.0f" : "%.2f", current) }
            focused = true
        }
    }

    private var currencySymbol: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.currencyCode = currency ?? "USD"
        return f.currencySymbol ?? "$"
    }
}
