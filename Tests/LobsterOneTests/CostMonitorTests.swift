import Testing
import Foundation
@testable import LobsterOne

private final class CountingFetcher: CostFetching, @unchecked Sendable {
    var calls = 0
    var error: Error?
    var amounts: [String: Double] = ["111111111111": 12.5]
    var names: [String: String]?
    func fetch(now: Date) async throws -> CostSnapshot {
        calls += 1
        if let error { throw error }
        return CostSnapshot(fetchedAt: now, currency: "USD", month: CostMath.month(now),
                            thisMonth: amounts, lastMonth: amounts.mapValues { $0 * 2 }, estimated: true,
                            accountNames: names)
    }
}

/// Holds a fetch open until released, to test what happens while a refresh is in flight.
private final class GatedFetcher: CostFetching, @unchecked Sendable {
    var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    func fetch(now: Date) async throws -> CostSnapshot {
        calls += 1
        await withCheckedContinuation { gate = $0 }
        return CostSnapshot(fetchedAt: now, currency: "USD", month: CostMath.month(now),
                            thisMonth: ["1": 1], lastMonth: [:], estimated: true)
    }
    var isWaiting: Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
private final class RecordingNotifier: AlertNotifying {
    var isEnabled = true
    var permissionRequests = 0
    var sent: [(id: String, title: String, body: String)] = []
    func requestPermission() { permissionRequests += 1 }
    func notify(id: String, title: String, body: String) { sent.append((id, title, body)) }
}

private final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// A monitor with its own temp cache, defaults suite, fetcher and clock.
@MainActor
private struct Rig {
    let fetcher = CountingFetcher()
    let notifier = RecordingNotifier()
    let clock = Clock(date("2026-11-10T09:00:00Z"))
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("x-test-\(UUID())").appendingPathComponent("aws-costs.json")
    let store = CostAlertStore(defaults: UserDefaults(suiteName: "x-test-\(UUID())")!)

    func monitor(connected: @escaping () -> Bool = { true },
                 fetcher makeFetcher: (() throws -> CostFetching)? = nil) -> CostMonitor {
        let f = fetcher, c = clock
        return CostMonitor(isConnected: connected, makeFetcher: makeFetcher ?? { f },
                           cacheURL: cache, alertStore: store, notifier: notifier, now: { c.now })
    }
}

// MARK: - CostMath

@Test func windowCoversLastMonthThroughEndOfThisMonth() {
    let w = CostMath.window(now: date("2026-01-15T10:00:00Z"))
    #expect(w.start == "2025-12-01")
    #expect(w.end == "2026-02-01")
}

@Test func forecastIsLinearOverCompletedDaysAndNilEarlyInMonth() throws {
    #expect(CostMath.forecast(monthToDate: 5, now: date("2026-11-03T12:00:00Z")) == nil)
    // 10 completed days of 30 in November: 10 -> 30.
    let f = try #require(CostMath.forecast(monthToDate: 10, now: date("2026-11-11T12:00:00Z")))
    #expect(abs(f - 30) < 0.001)
}

@Test func snapshotFromRowsSplitsMonths() {
    let snap = CostRow.snapshot([
        CostRow(periodStart: "2026-10-01", account: "a", amount: 4, unit: "USD", estimated: false),
        CostRow(periodStart: "2026-11-01", account: "a", amount: 1.5, unit: "USD", estimated: true),
        CostRow(periodStart: "2026-11-01", account: "b", amount: 2, unit: "USD", estimated: true),
    ], now: date("2026-11-10T00:00:00Z"))
    #expect(snap.month == "2026-11")
    #expect(snap.thisMonth == ["a": 1.5, "b": 2])
    #expect(snap.lastMonth == ["a": 4])
    #expect(snap.estimated)
}

@Test func snapshotFromNoRowsIsEmptyUSD() {
    let snap = CostRow.snapshot([], now: date("2026-11-10T00:00:00Z"))
    #expect(snap.currency == "USD")
    #expect(snap.thisMonth.isEmpty)
    #expect(!snap.estimated)
}

@Test func accountsIncludeLastMonthOnlySpendBiggestFirst() {
    let now = date("2026-11-20T00:00:00Z")
    let snap = CostSnapshot(fetchedAt: now, currency: "USD", month: "2026-11",
                            thisMonth: ["a": 1, "b": 30, "c": 5], lastMonth: ["d": 7, "c": 2], estimated: true)
    let accounts = CostMath.accounts(snapshot: snap, now: now)
    #expect(accounts.map(\.accountId) == ["b", "c", "a", "d"])
    #expect(accounts[1].lastMonth == 2)
    #expect(accounts[3].thisMonth == 0)
    #expect(accounts[0].id == "account:b")
    #expect(accounts[0].forecast != nil)
}

@Test func accountsUseOrganizationNames() {
    let now = date("2026-11-10T09:00:00Z")
    let snap = CostSnapshot(fetchedAt: now, currency: "USD", month: "2026-11",
                            thisMonth: ["9": 2, "8": 1], lastMonth: [:], estimated: true,
                            accountNames: ["9": "LobsterOne prod"])
    let accounts = CostMath.accounts(snapshot: snap, now: now)
    #expect(accounts.map(\.displayName) == ["LobsterOne prod", "Account 8"])
}

@Test func accountsIgnoreStaleMonth() {
    let snap = CostSnapshot(fetchedAt: date("2026-11-20T00:00:00Z"), currency: "USD", month: "2026-11",
                            thisMonth: ["a": 1], lastMonth: [:], estimated: true)
    #expect(CostMath.accounts(snapshot: snap, now: date("2026-12-05T00:00:00Z")).isEmpty)
    #expect(CostMath.accounts(snapshot: nil, now: date("2026-12-05T00:00:00Z")).isEmpty)
}

// MARK: - CostError

@Test func errorMappingFromAWSCodes() {
    #expect(CostError.explain(code: "AccessDeniedException",
                              message: "User not enabled for cost explorer access") == .notEnabled)
    #expect(CostError.explain(code: "AccessDeniedException", message: "nope") == .accessDenied)
    #expect(CostError.explain(code: "DataUnavailableException", message: nil) == .notEnabled)
    #expect(CostError.explain(code: "ExpiredTokenException", message: nil) == .needsSignIn(profile: nil))
    #expect(CostError.explain(code: "ExpiredToken", message: nil, profile: "work") == .needsSignIn(profile: "work"))
    #expect(CostError.explain(code: "UnauthorizedException", message: nil, profile: "sso") == .needsSignIn(profile: "sso"))
    #expect(CostError.explain(code: "UnrecognizedClientException", message: nil) == .credentialsInvalid)
    #expect(CostError.explain(code: "InvalidClientTokenId", message: nil) == .credentialsInvalid)
    #expect(CostError.explain(code: "SignatureDoesNotMatch", message: nil) == .credentialsInvalid)
    #expect(CostError.explain(code: "ThrottlingException", message: "Rate exceeded") == .other("Rate exceeded"))
    #expect(CostError.explain(code: "Weird", message: nil) == .other("Weird"))
}

@Test func errorMappingFromThrownErrors() {
    #expect(CostError.explain(CostError.cliMissing) == .cliMissing)
    #expect(CostError.explain(URLError(.notConnectedToInternet)) == .network)
    #expect(CostError.explain(NSError(domain: NSURLErrorDomain, code: -1001)) == .network)
    if case .other = CostError.explain(NSError(domain: "x", code: 1)) {} else { Issue.record("expected .other") }
}

// MARK: - CostErrorCopy

@Test func errorCopyGivesEachCaseATitleAndNoExclamations() {
    let all: [CostError] = [.notConnected, .needsSignIn(profile: "work"), .needsSignIn(profile: nil), .cliMissing,
                            .notEnabled, .accessDenied, .credentialsInvalid, .network, .other("boom")]
    for error in all {
        let info = CostErrorCopy.describe(error)
        #expect(!info.title.isEmpty)
        #expect(!info.detail.isEmpty)
        #expect(!(info.title + info.detail).contains("!"))
        #expect(!(info.title + info.detail).contains("TigerSoup"))
    }
}

@Test func errorCopyActions() {
    let settings = CostErrorCopy.Action(title: "Open Settings", target: .openSettings)
    #expect(CostErrorCopy.describe(.notConnected).action == settings)
    #expect(CostErrorCopy.describe(.credentialsInvalid).action == settings)
    #expect(CostErrorCopy.describe(.notEnabled).action?.target == .url(CostLinks.costExplorer))
    #expect(CostErrorCopy.describe(.accessDenied).action?.target == .url(CostLinks.iamBillingAccess))
    #expect(CostErrorCopy.describe(.cliMissing).action?.target == .url(CostLinks.installCLI))
    #expect(CostErrorCopy.describe(.network).action == nil)
    #expect(CostErrorCopy.describe(.other("boom")).detail == "boom")
    #expect(CostErrorCopy.describe(.network).command == nil)
}

@Test func errorCopyNeedsSignInCarriesTheCommand() {
    let info = CostErrorCopy.describe(.needsSignIn(profile: "work"))
    #expect(info.command == "aws sso login --profile work")
    #expect(info.detail.contains("aws sso login --profile work"))
    #expect(CostErrorCopy.describe(.needsSignIn(profile: nil)).command == "aws sso login")
}

@Test func signInCommandQuotesOddProfileNames() {
    #expect(CostErrorCopy.signInCommand(profile: "dev-1.admin") == "aws sso login --profile dev-1.admin")
    #expect(CostErrorCopy.signInCommand(profile: "my profile") == "aws sso login --profile 'my profile'")
    #expect(CostErrorCopy.signInCommand(profile: "a'b;rm") == "aws sso login --profile 'a'\\''b;rm'")
    #expect(CostErrorCopy.signInCommand(profile: "") == "aws sso login")
}

// MARK: - CostFormat

@Test func usdAlwaysUsesDollarSign() {
    #expect(CostFormat.money(20, currency: "USD") == "$20.00")
    #expect(CostFormat.short(1234.7, currency: "USD") == "$1,235")
    #expect(CostFormat.short(4.12, currency: nil) == "$4.12")
}

// MARK: - CostMonitor

@MainActor @Test func menuOpenFetchesOnceThenNotAgainWithinAnHour() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()
    #expect(rig.fetcher.calls == 1)
    #expect(m.monthToDateTotal == 12.5)

    rig.clock.now += 59 * 60
    await m.menuOpened()
    await m.menuOpened()
    #expect(rig.fetcher.calls == 1, "repeated opens inside an hour must not pay again")

    rig.clock.now += 2 * 60
    await m.menuOpened()
    #expect(rig.fetcher.calls == 2)
}

@MainActor @Test func dailyRefreshOnlyAfter24Hours() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.refresh(ifOlderThan: CostMonitor.dailyInterval)
    rig.clock.now += 23 * 3600
    await m.refresh(ifOlderThan: CostMonitor.dailyInterval)
    #expect(rig.fetcher.calls == 1)
    rig.clock.now += 3600
    await m.refresh(ifOlderThan: CostMonitor.dailyInterval)
    #expect(rig.fetcher.calls == 2)
}

@MainActor @Test func notConnectedNeverCallsAWSAndStaysSilent() async {
    let rig = Rig()
    var madeFetcher = false
    let f = rig.fetcher
    let m = rig.monitor(connected: { false }, fetcher: { madeFetcher = true; return f })
    await m.menuOpened()
    await m.refresh(ifOlderThan: 0)
    await m.refreshNow()
    #expect(rig.fetcher.calls == 0)
    #expect(!madeFetcher)
    #expect(m.error == nil)
    #expect(m.monthToDateTotal == nil)
}

@MainActor @Test func connectingLaterFetchesOnNextOpen() async {
    let rig = Rig()
    var connected = false
    let m = rig.monitor(connected: { connected })
    await m.menuOpened()
    connected = true
    await m.menuOpened()
    #expect(rig.fetcher.calls == 1)
}

@MainActor @Test func failuresAreThrottledToo() async {
    let rig = Rig()
    rig.fetcher.error = CostError.notEnabled
    let m = rig.monitor()
    await m.menuOpened()
    await m.menuOpened()
    #expect(rig.fetcher.calls == 1)
    #expect(m.error == .notEnabled)
}

@MainActor @Test func fetcherThatCannotBeMadeSendsNothingAndDoesNotBlockTheNextOpen() async {
    let rig = Rig()
    var ready = false
    let f = rig.fetcher
    let m = rig.monitor(fetcher: {
        guard ready else { throw CostError.needsSignIn(profile: "work") }
        return f
    })
    await m.menuOpened()
    #expect(m.error == .needsSignIn(profile: "work"))
    ready = true
    await m.menuOpened()
    #expect(rig.fetcher.calls == 1)
    #expect(m.error == nil)
}

@MainActor @Test func cacheSurvivesRelaunchSoNoExtraCall() async {
    let rig = Rig()
    await rig.monitor().menuOpened()
    rig.clock.now += 10 * 60
    let relaunched = rig.monitor()
    await relaunched.menuOpened()
    #expect(rig.fetcher.calls == 1)
    #expect(relaunched.monthToDateTotal == 12.5)
}

@MainActor @Test func cacheIsOwnerOnly() async throws {
    let rig = Rig()
    await rig.monitor().menuOpened()
    let attrs = try FileManager.default.attributesOfItem(atPath: rig.cache.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.cache.deletingLastPathComponent().path)
    #expect(leftovers == ["aws-costs.json"])
}

@MainActor @Test func newMonthRefetchesButHourlyCapStillApplies() async {
    let rig = Rig()
    rig.clock.now = date("2026-11-30T23:30:00Z")
    let m = rig.monitor()
    await m.menuOpened()
    rig.clock.now = date("2026-12-01T00:10:00Z")
    await m.menuOpened()
    #expect(rig.fetcher.calls == 1, "the hourly cap still applies across the month boundary")
    #expect(m.monthToDateTotal == nil, "last month's snapshot says nothing about this month")
    rig.clock.now = date("2026-12-01T00:40:00Z")
    await m.menuOpened()
    #expect(rig.fetcher.calls == 2)
}

@MainActor @Test func refreshNowBypassesTheAgeCheck() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()
    await m.refreshNow()
    #expect(rig.fetcher.calls == 2)
}

@MainActor @Test func refreshNowRefusesWhileARefreshIsInFlight() async {
    let rig = Rig()
    let gated = GatedFetcher()
    let m = rig.monitor(fetcher: { gated })
    let first = Task { await m.refreshNow() }
    while !gated.isWaiting { await Task.yield() }
    #expect(m.isRefreshing)
    await m.refreshNow()
    await m.menuOpened()
    #expect(gated.calls == 1)
    gated.release()
    await first.value
    #expect(!m.isRefreshing)
    #expect(m.monthToDateTotal == 1)
}

@MainActor @Test func resetClearsSnapshotErrorCacheAndThrottle() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()
    #expect(FileManager.default.fileExists(atPath: rig.cache.path))

    m.reset()
    #expect(m.snapshot == nil)
    #expect(m.accounts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: rig.cache.path))
    #expect(rig.monitor().snapshot == nil, "a relaunch must not bring the old figures back")

    // The throttle went with it: the next open fetches straight away.
    await m.menuOpened()
    #expect(rig.fetcher.calls == 2)
}

@MainActor @Test func resetClearsError() async {
    let rig = Rig()
    rig.fetcher.error = CostError.accessDenied
    let m = rig.monitor()
    await m.menuOpened()
    #expect(m.error == .accessDenied)
    m.reset()
    #expect(m.error == nil)
}

@MainActor @Test func accountsAndTotalsAreWholeOrganization() async {
    let rig = Rig()
    rig.fetcher.amounts = ["111111111111": 1, "222222222222": 30, "333333333333": 5]
    rig.fetcher.names = ["222222222222": "Prod"]
    let m = rig.monitor()
    await m.menuOpened()
    #expect(m.accounts.map(\.accountId) == ["222222222222", "333333333333", "111111111111"])
    #expect(m.accounts[0].displayName == "Prod")
    #expect(m.accounts[1].displayName == "Account 333333333333")
    #expect(m.monthToDateTotal == 36)
    #expect(m.lastMonthTotal == 72)
    #expect(m.snapshot?.accountNames == ["222222222222": "Prod"])
    #expect(rig.monitor().snapshot?.accountNames == ["222222222222": "Prod"], "names survive the cache")
    #expect(rig.fetcher.calls == 1)
}

@MainActor @Test func forecastTotalFollowsMonthToDate() async throws {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()
    // 9 completed days of 30: 12.5 -> 41.67.
    let f = try #require(m.forecastTotal)
    #expect(abs(f - 12.5 / 9 * 30) < 0.001)
}

@MainActor @Test func oldCacheWithoutNamesStillLoads() throws {
    let rig = Rig()
    let json = #"{"fetchedAt":"2026-11-10T08:00:00Z","currency":"USD","month":"2026-11","thisMonth":{"111111111111":3},"lastMonth":{},"estimated":true}"#
    try FileManager.default.createDirectory(at: rig.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: rig.cache, atomically: true, encoding: .utf8)
    let m = rig.monitor()
    #expect(m.snapshot?.thisMonth["111111111111"] == 3)
    #expect(m.snapshot?.accountNames == nil)
}

@MainActor @Test func stopCancelsTheSchedule() async {
    let rig = Rig()
    let m = rig.monitor()
    m.startDailySchedule()
    while rig.fetcher.calls == 0 { await Task.yield() }
    m.stop()
    m.startDailySchedule()   // allowed again after stop
    m.stop()
    #expect(rig.fetcher.calls >= 1)
}

// MARK: - Alerts

private let account = "account:111111111111"

@MainActor @Test func alertsOnceWhenSpendPassesAmount() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()                      // $12.50 this month
    m.setAlertLimit(20, for: account)
    #expect(rig.notifier.permissionRequests == 1)
    #expect(rig.notifier.sent.isEmpty, "under the amount: no alert")

    rig.fetcher.amounts = ["111111111111": 25]
    rig.clock.now += 25 * 3600
    await m.refresh(ifOlderThan: CostMonitor.dailyInterval)
    #expect(rig.notifier.sent.count == 1)
    #expect(rig.notifier.sent.first?.title == "Account 111111111111 passed $20.00")
    #expect(rig.notifier.sent.first?.body == "It has spent $25.00 on AWS so far this month.")

    rig.fetcher.amounts = ["111111111111": 40]
    rig.clock.now += 25 * 3600
    await m.refresh(ifOlderThan: CostMonitor.dailyInterval)
    #expect(rig.notifier.sent.count == 1, "only once per month")
}

@MainActor @Test func settingAmountBelowCurrentSpendAlertsImmediatelyWithoutAWSCall() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()
    m.setAlertLimit(10, for: account)
    #expect(rig.notifier.sent.count == 1)
    #expect(rig.fetcher.calls == 1)
}

@MainActor @Test func newMonthAlertsAgain() async {
    let rig = Rig()
    let m = rig.monitor()
    await m.menuOpened()
    m.setAlertLimit(10, for: account)
    #expect(rig.notifier.sent.count == 1)
    rig.clock.now = date("2026-12-02T09:00:00Z")
    await m.menuOpened()
    #expect(rig.notifier.sent.count == 2)
}

@MainActor @Test func alertDueWhileSwitchedOffFiresOnceSwitchedBackOn() async {
    let rig = Rig()
    let m = rig.monitor()
    rig.notifier.isEnabled = false
    m.setAlertLimit(10, for: account)
    await m.menuOpened()
    #expect(rig.notifier.sent.isEmpty, "switched off: nothing shown, nothing used up")
    rig.notifier.isEnabled = true
    rig.clock.now += CostMonitor.menuOpenInterval + 1
    await m.menuOpened()
    #expect(rig.notifier.sent.count == 1)
}

@MainActor @Test func removingAlertStopsIt() async {
    let rig = Rig()
    let m = rig.monitor()
    m.setAlertLimit(10, for: account)
    m.setAlertLimit(nil, for: account)
    await m.menuOpened()
    #expect(rig.notifier.sent.isEmpty)
    #expect(m.alertLimits[account] == nil)
}

@MainActor @Test func alertLimitsPersistInTheStore() {
    let rig = Rig()
    rig.monitor().setAlertLimit(15, for: account)
    #expect(rig.monitor().alertLimits == [account: 15])
    #expect(rig.store.defaults.dictionary(forKey: "awsCostAlertLimits") as? [String: Double] == [account: 15])
}

@Test func parseAmount() {
    #expect(CostAlerts.parseAmount("20") == 20)
    #expect(CostAlerts.parseAmount("$12,50") == 12.5)
    #expect(CostAlerts.parseAmount("") == nil)
    #expect(CostAlerts.parseAmount("0") == nil)
    #expect(CostAlerts.parseAmount("lots") == nil)
}
