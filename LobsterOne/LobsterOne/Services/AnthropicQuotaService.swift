import Combine
import Foundation

/// Orchestrates real quota fetching:
/// 1. Credentials file → Anthropic OAuth API (real utilization %)
/// 2. Keychain via CLI → Anthropic OAuth API
/// 3. Falls through — PollingService uses Robocog P90 estimate
@MainActor
final class AnthropicQuotaService: ObservableObject {
    @Published var state: AnthropicQuotaState = .empty

    private let credentialService = ClaudeCredentialService()
    private let apiClient = AnthropicAPIClient()

    /// Last source line logged, so the switch between real quota and the ~ estimate
    /// shows once in the log, with its reason, instead of on every poll.
    private var lastSourceNote: String?

    private func noteSource(_ note: String) {
        guard note != lastSourceNote else { return }
        lastSourceNote = note
        DebugLog.shared.log(note)
    }

    /// Fetch real quota and optionally sync the snapshot to the Robocog backend.
    func fetch(syncTo lobsterClient: APIClient? = nil, apiKey: String? = nil) async {
        // Delegates a CLI-side token refresh when the stored token is expired
        // (e.g. overnight with no claude session), so we stay on real quota
        // instead of degrading to the ~P90 estimate.
        guard let creds = await credentialService.readCredentialsRefreshingIfNeeded() else {
            state.source = .robocogP90
            noteSource("Quota source: estimate (~), no valid Claude token")
            return
        }

        do {
            let usage = try await apiClient.fetchUsage(accessToken: creds.accessToken)
            state = mapToState(usage, creds: creds)
            noteSource("Quota source: real, from the Anthropic usage API")
            DebugLog.shared.log("Anthropic quota OK: 5h=\(state.fiveHourPct.map { "\(Int($0))%" } ?? "n/a"), 7d=\(state.sevenDayPct.map { "\(Int($0))%" } ?? "n/a")")

            // Sync to backend (fire-and-forget)
            if let client = lobsterClient, let key = apiKey {
                let payload = buildPayload(usage, creds: creds)
                Task {
                    do {
                        try await client.postQuotaSnapshot(payload, apiKey: key)
                        DebugLog.shared.log("Quota snapshot synced to backend")
                    } catch {
                        DebugLog.shared.log("Quota snapshot sync failed: \(error)")
                    }
                }
            }
        } catch {
            let msg = (error as? AnthropicAPIError)?.displayMessage ?? error.localizedDescription
            DebugLog.shared.log("Anthropic API failed: \(msg), falling back to P90")
            state.source = .robocogP90
            noteSource("Quota source: estimate (~), Anthropic usage API failed: \(msg)")
        }
    }

    // MARK: - Mapping

    private func mapToState(_ usage: AnthropicUsageResponse, creds: ClaudeOAuthCredentials) -> AnthropicQuotaState {
        var s = AnthropicQuotaState()
        s.source = .oauthAPI
        s.lastUpdated = Date()
        s.subscriptionType = creds.subscriptionType
        s.rateLimitTier = creds.rateLimitTier

        if let w = usage.fiveHour {
            s.fiveHourPct = w.utilization
            if let r = w.resetsAt { s.fiveHourResetsAt = parseDate(r) }
        }
        if let w = usage.sevenDay {
            s.sevenDayPct = w.utilization
            if let r = w.resetsAt { s.sevenDayResetsAt = parseDate(r) }
        }
        if let w = usage.sevenDaySonnet {
            s.sonnetPct = w.utilization
        }
        if let w = usage.sevenDayOpus {
            s.opusPct = w.utilization
        }
        if let extra = usage.extraUsage, extra.isEnabled {
            s.extraUsageEnabled = true
            // Anthropic API returns cents — convert to dollars
            s.usedCredits = extra.usedCredits.map { $0 / 100.0 }
            s.monthlyLimit = extra.monthlyLimit.map { $0 / 100.0 }
        }

        return s
    }

    private func buildPayload(_ usage: AnthropicUsageResponse, creds: ClaudeOAuthCredentials) -> QuotaSnapshotPayload {
        QuotaSnapshotPayload(
            fiveHourPct: usage.fiveHour?.utilization,
            fiveHourResetsAt: usage.fiveHour?.resetsAt,
            sevenDayPct: usage.sevenDay?.utilization,
            sevenDayResetsAt: usage.sevenDay?.resetsAt,
            sonnetPct: usage.sevenDaySonnet?.utilization,
            opusPct: usage.sevenDayOpus?.utilization,
            extraCreditsUsed: usage.extraUsage?.isEnabled == true ? (usage.extraUsage?.usedCredits).map { $0 / 100.0 } : nil,
            monthlyLimit: usage.extraUsage?.isEnabled == true ? (usage.extraUsage?.monthlyLimit).map { $0 / 100.0 } : nil,
            subscriptionType: creds.subscriptionType,
            rateLimitTier: creds.rateLimitTier
        )
    }

    private func parseDate(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
