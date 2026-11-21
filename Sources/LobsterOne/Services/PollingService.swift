import AppKit
import Combine
import CoreGraphics

@MainActor
final class PollingService: ObservableObject {
    let activeInterval: TimeInterval = Constants.pollingActiveInterval
    let idleInterval: TimeInterval = Constants.pollingIdleInterval

    @Published var quotaState: QuotaState = .empty
    @Published var authFailed = false
    @Published var unreadNotificationCount: Int = 0
    /// Open town invites from the last count call; nil until a backend that sends them answers.
    @Published var townInvites: [TownInvite]?
    @Published var sevenDayBurn: SevenDayBurn?

    /// Called at the start of each poll cycle so other services can piggyback.
    var onPollCycleStarted: (() -> Void)?

    private var timer: Timer?
    private let apiClient: APIClient
    private let activityMonitor: ActivityMonitor
    private let clientPolicy: ClientPolicyService
    private var sleepCancellable: AnyCancellable?
    private let screensaver = ScreensaverWatch()
    private var tokenRate = TokenRate()
    /// Overridable so tests need no real screensaver.
    var isScreensaverShowing: (() -> Bool)?

    init(
        apiClient: APIClient = APIClient(),
        activityMonitor: ActivityMonitor = ActivityMonitor(),
        clientPolicy: ClientPolicyService? = nil
    ) {
        self.apiClient = apiClient
        self.activityMonitor = activityMonitor
        self.clientPolicy = clientPolicy ?? ClientPolicyService()
    }

    func currentInterval(secondsSinceLastInput: TimeInterval) -> TimeInterval {
        if clientPolicy.current.level == .block {
            return Constants.pollingBlockedInterval
        }
        // A screensaver means the user is idle, which would otherwise mean the slowest cadence
        // exactly when the figures are on display.
        if isScreensaverShowing?() ?? screensaver.isShowing {
            return Constants.pollingScreensaverInterval
        }
        return secondsSinceLastInput >= activityMonitor.idleThreshold ? idleInterval : activeInterval
    }

    func start(apiKey: String) {
        apiClient.setAPIKey(apiKey)
        sleepCancellable = activityMonitor.$isSleeping
            .dropFirst()
            .sink { [weak self] sleeping in
            guard let self else { return }
            Task { @MainActor in
                if sleeping {
                    self.timer?.invalidate()
                } else {
                    await self.fetchAndScheduleNext()
                }
            }
        }
        screensaver.onStart = { [weak self] in self?.refreshNow() }
        screensaver.start()
        Task { await fetchAndScheduleNext() }
    }

    func stop() {
        screensaver.stop()
        timer?.invalidate()
        timer = nil
        sleepCancellable?.cancel()
        sleepCancellable = nil
    }

    func refreshNow() {
        timer?.invalidate()
        timer = nil
        DebugLog.shared.log("Manual refresh triggered")
        Task { await fetchAndScheduleNext() }
    }

    private func fetchAndScheduleNext() async {
        onPollCycleStarted?()
        await fetchQuota()
        await fetchNotificationCount()
        scheduleNext()
    }

    /// Just the count call, for when a push says something changed. Skips the quota calls.
    func refreshNotificationCount() {
        Task { await fetchNotificationCount() }
    }

    private func fetchNotificationCount() async {
        do {
            let response = try await apiClient.fetchNotificationCount()
            unreadNotificationCount = response.unread
            if let invites = response.townInvites { townInvites = invites }
        } catch {
            DebugLog.shared.log("Notification count fetch failed: \(error)")
        }
    }

    func markAllNotificationsRead() {
        unreadNotificationCount = 0
        Task {
            do {
                try await apiClient.markAllNotificationsRead()
            } catch {
                DebugLog.shared.log("Mark all notifications read failed: \(error)")
            }
        }
    }

    /// Whether the combined /status endpoint is available (assume yes until proven otherwise)
    private var useStatusEndpoint = true

    private func fetchQuota() async {
        DebugLog.shared.log("Poll starting")

        // Try combined endpoint first (single request instead of two)
        if useStatusEndpoint {
            do {
                let status = try await apiClient.fetchStatus()
                clientPolicy.update(status.clientPolicy)
                let realtime = status.realtime
                let quota = status.quota
                DebugLog.shared.log("Poll OK (status): \(realtime.tokens.total) tokens, \(quota.percentUsed)%")
                sevenDayBurn = realtime.seven_day.map { SevenDayBurn.from($0) }
                quotaState = QuotaState(
                    usedTokens: realtime.tokens.total,
                    usedRequests: quota.usedRequests,
                    limitRequests: quota.limitRequests,
                    planTier: quota.planTier,
                    percentUsed: quota.percentUsed,
                    lastUpdated: Date(),
                    isOffline: false,
                    offlineReason: "",
                    hasQuota: true,
                    isRealQuota: false,
                    anthropicState: nil,
                    tokensPerMinute: tokenRate.record(tokens: realtime.tokens.total)
                )
                return
            } catch let error as APIError {
                if case .httpError(let code, _) = error, code == 404 {
                    // Backend doesn't have /status yet — fall back to two-call pattern
                    DebugLog.shared.log("Status endpoint returned 404, falling back to separate calls")
                    useStatusEndpoint = false
                } else if case .httpError(let code, _) = error, code == 403 {
                    DebugLog.shared.log("Poll failed: API key rejected (403). Triggering re-authentication.")
                    authFailed = true
                    stop()
                    return
                } else {
                    // Other error — fall through to legacy path for partial-success handling
                    DebugLog.shared.log("Status endpoint failed: \(error.displayMessage), falling back to separate calls")
                }
            } catch {
                DebugLog.shared.log("Status endpoint failed: \(error.localizedDescription), falling back to separate calls")
            }
        }

        // Fallback: fetch realtime and quota independently
        var realtime: RealtimeResponse?
        var realtimeError: Error?
        var quota: QuotaResponse?
        var quotaError: Error?

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                do {
                    realtime = try await self.apiClient.fetchRealtime()
                } catch {
                    realtimeError = error
                }
            }
            group.addTask { @MainActor in
                do {
                    quota = try await self.apiClient.fetchQuota()
                } catch {
                    quotaError = error
                }
            }
        }

        if let realtime, let quota {
            // Both succeeded — full display
            DebugLog.shared.log("Poll OK: \(realtime.tokens.total) tokens, \(quota.percentUsed)%")
            sevenDayBurn = realtime.seven_day.map { SevenDayBurn.from($0) }
            quotaState = QuotaState(
                usedTokens: realtime.tokens.total,
                usedRequests: quota.usedRequests,
                limitRequests: quota.limitRequests,
                planTier: quota.planTier,
                percentUsed: quota.percentUsed,
                lastUpdated: Date(),
                isOffline: false,
                offlineReason: "",
                hasQuota: true,
                isRealQuota: false,
                anthropicState: nil,
                tokensPerMinute: tokenRate.record(tokens: realtime.tokens.total)
            )
        } else if let realtime {
            // Only realtime succeeded — show tokens, keep stale quota
            let reason = (quotaError as? APIError)?.displayMessage ?? quotaError?.localizedDescription ?? "Unknown"
            DebugLog.shared.log("Poll partial: realtime OK, quota failed (\(reason))")
            sevenDayBurn = realtime.seven_day.map { SevenDayBurn.from($0) }
            quotaState = QuotaState(
                usedTokens: realtime.tokens.total,
                usedRequests: quotaState.usedRequests,
                limitRequests: quotaState.limitRequests,
                planTier: quotaState.planTier,
                percentUsed: quotaState.percentUsed,
                lastUpdated: Date(),
                isOffline: false,
                offlineReason: reason,
                hasQuota: false,
                isRealQuota: false,
                anthropicState: nil,
                tokensPerMinute: tokenRate.record(tokens: realtime.tokens.total)
            )
        } else {
            // Both failed — check if auth issue (403)
            let isForbidden = [realtimeError, quotaError].contains { error in
                if case .httpError(let code, _) = error as? APIError, code == 403 { return true }
                return false
            }
            if isForbidden {
                DebugLog.shared.log("Poll failed: API key rejected (403). Triggering re-authentication.")
                authFailed = true
                stop()
                return
            }

            let reason = (realtimeError as? APIError)?.displayMessage ?? realtimeError?.localizedDescription ?? "Unknown"
            DebugLog.shared.log("Poll failed: \(reason)")
            quotaState.isOffline = true
            quotaState.offlineReason = reason
            quotaState.lastUpdated = Date()
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard !activityMonitor.isSleeping else { return }

        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let interval = currentInterval(secondsSinceLastInput: idleSeconds)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchAndScheduleNext() }
        }
    }
}
