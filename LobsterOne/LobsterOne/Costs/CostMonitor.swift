import Combine
import Foundation

/// Keeps the AWS cost figures current while spending as little as possible: each Cost
/// Explorer request costs the person $0.01.
///
/// - Automatically: at most once a day.
/// - When the menu opens: only if the figures are over an hour old. AWS refreshes
///   its cost data a few times a day, so fetching more often buys nothing.
/// - Never until AWS is connected. The feature is opt-in, so until then it stays silent
///   and shows no error.
@MainActor
final class CostMonitor: ObservableObject {
    static let dailyInterval: TimeInterval = 24 * 3600
    static let menuOpenInterval: TimeInterval = 3600

    @Published private(set) var snapshot: CostSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: CostError?
    /// Monthly alert amounts, keyed by `AccountCost.id`.
    @Published private(set) var alertLimits: [String: Double] = [:]

    private let isConnected: () -> Bool
    private let makeFetcher: () throws -> CostFetching
    private let cacheURL: URL?
    private let now: () -> Date
    /// When a request was last actually sent, so failures are throttled too.
    private var lastAttempt: Date?
    private var schedule: Task<Void, Never>?
    private let alertStore: CostAlertStore
    private let notifier: AlertNotifying

    init(isConnected: @escaping () -> Bool,
         makeFetcher: @escaping () throws -> CostFetching,
         cacheURL: URL? = CostMonitor.defaultCacheURL,
         alertStore: CostAlertStore = CostAlertStore(),
         notifier: AlertNotifying,
         now: @escaping () -> Date = Date.init) {
        self.isConnected = isConnected
        self.makeFetcher = makeFetcher
        self.cacheURL = cacheURL
        self.alertStore = alertStore
        self.notifier = notifier
        self.now = now
        self.snapshot = cacheURL.flatMap(Self.load)
        self.alertLimits = alertStore.limits
    }

    /// Every account with spend this month or last, biggest first.
    var accounts: [AccountCost] {
        CostMath.accounts(snapshot: snapshot, now: now(), fallbackNames: localNames())
    }

    /// Names to use for accounts AWS didn't name, by account id. Set by the owner.
    var localNames: () -> [String: String] = { [:] }

    /// Whole-Organization total, so it matches the AWS bill.
    var monthToDateTotal: Double? {
        guard let snapshot, snapshot.month == CostMath.month(now()) else { return nil }
        return snapshot.thisMonthTotal
    }

    var lastMonthTotal: Double? {
        guard let snapshot, snapshot.month == CostMath.month(now()) else { return nil }
        return snapshot.lastMonthTotal
    }

    var forecastTotal: Double? {
        monthToDateTotal.flatMap { CostMath.forecast(monthToDate: $0, now: now()) }
    }

    /// Sets (or clears, with nil) an account's alert amount. Checked straight
    /// away against the figures already on hand; no AWS request.
    func setAlertLimit(_ amount: Double?, for id: String) {
        if amount != nil, alertLimits.isEmpty { notifier.requestPermission() }
        alertStore.setLimit(amount, for: id)
        alertLimits = alertStore.limits
        sendDueAlerts()
    }

    private func sendDueAlerts() {
        guard notifier.isEnabled, let snapshot, snapshot.month == CostMath.month(now()) else { return }
        let currency = snapshot.currency
        let subjects = accounts.map { CostAlerts.Subject(id: $0.id, name: $0.displayName, thisMonth: $0.thisMonth) }
        for (subject, limit) in CostAlerts.due(subjects, store: alertStore, month: snapshot.month) {
            notifier.notify(
                id: "aws-cost-alert-\(subject.id)-\(snapshot.month)",
                title: "\(subject.name) passed \(CostFormat.money(limit, currency: currency))",
                body: "It has spent \(CostFormat.money(subject.thisMonth, currency: currency)) on AWS so far this month.")
            alertStore.markNotified(subject.id, month: snapshot.month)
        }
    }

    func menuOpened() async {
        await refresh(ifOlderThan: Self.menuOpenInterval)
    }

    /// Checks hourly whether the daily refresh is due. Checking is free; only
    /// the refresh itself calls AWS.
    func startDailySchedule() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(ifOlderThan: Self.dailyInterval)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func stop() {
        schedule?.cancel()
        schedule = nil
    }

    func refresh(ifOlderThan maxAge: TimeInterval) async {
        guard !isRefreshing, isConnected() else { return }
        let current = now()
        let snapshotIsCurrent = snapshot?.month == CostMath.month(current)
        let lastSent = [snapshotIsCurrent ? snapshot?.fetchedAt : nil, lastAttempt].compactMap { $0 }.max()
        if let lastSent, current.timeIntervalSince(lastSent) < maxAge { return }
        await fetch(now: current)
    }

    /// The person pressed Refresh: fetch now whatever the age of the figures. Each call
    /// costs the person $0.01 in AWS charges, so the UI should only call this on an explicit
    /// press. Still does nothing while a refresh is in flight or AWS isn't connected.
    func refreshNow() async {
        guard !isRefreshing, isConnected() else { return }
        await fetch(now: now())
    }

    /// Forgets everything fetched, for a disconnect or sign-out. Alert amounts stay, so
    /// reconnecting the same accounts brings them back.
    func reset() {
        snapshot = nil
        error = nil
        lastAttempt = nil
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    private func fetch(now current: Date) async {
        let fetcher: CostFetching
        do { fetcher = try makeFetcher() }
        catch { self.error = CostError.explain(error); return }

        isRefreshing = true
        lastAttempt = current
        defer { isRefreshing = false }
        do {
            let fresh = try await fetcher.fetch(now: current)
            snapshot = fresh
            self.error = nil
            if let cacheURL { Self.save(fresh, to: cacheURL) }
            sendDueAlerts()
        } catch {
            self.error = CostError.explain(error)
        }
    }

    // MARK: - Cache

    nonisolated static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LobsterOne", isDirectory: true)
            .appendingPathComponent("aws-costs.json")
    }

    private static func load(_ url: URL) -> CostSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CostSnapshot.self, from: data)
    }

    /// Written to a 0600 temp file and renamed over the cache, so the file is never readable
    /// by other users and a crash mid-write can't leave half a file.
    private static func save(_ snapshot: CostSnapshot, to url: URL) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, url.path) != 0 { try? fm.removeItem(at: temp) }
    }
}
