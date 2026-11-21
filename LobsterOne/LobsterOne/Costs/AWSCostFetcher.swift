import Foundation

/// Reads this month's and last month's spend per account from Cost Explorer, then the
/// account names from Organizations. One Cost Explorer request per fetch (more only if AWS
/// pages the answer), each billed at $0.01; the names are free.
nonisolated struct AWSCostFetcher: CostFetching {
    let api: AWSAPI

    func fetch(now: Date) async throws -> CostSnapshot {
        let window = CostMath.window(now: now)
        let rows: [AWSCostRow]
        do {
            rows = try await api.getCostAndUsage(start: window.start, end: window.end)
        } catch {
            throw Self.explain(error)
        }
        var snapshot = CostRow.snapshot(rows.map {
            CostRow(periodStart: $0.periodStart, account: $0.account, amount: $0.amount,
                    unit: $0.unit, estimated: $0.estimated)
        }, now: now)
        // Only the management account may list the organization; anywhere else AWS says no,
        // which is normal, so the rows just show account ids.
        if let names = try? await api.listAccountNames(), !names.isEmpty {
            snapshot.accountNames = names
        }
        return snapshot
    }

    /// The AWS client's errors in the words the menu uses. Anything it doesn't know becomes a
    /// short `.other`, never a key or the CLI's output (the client never carries those).
    static func explain(_ error: Error) -> CostError {
        guard let error = error as? AWSClientError else { return CostError.explain(error) }
        switch error {
        case .notConnected: return .notConnected
        case .cliMissing: return .cliMissing
        case .needsSignIn(let profile): return .needsSignIn(profile: profile)
        case .credentialsInvalid: return .credentialsInvalid
        case .accessDenied: return .accessDenied
        case .costExplorerNotEnabled: return .notEnabled
        case .network: return .network
        case .invalidProfileName:
            return .other("That profile name has characters LobsterOne won't pass to the AWS CLI. Pick another profile in Settings.")
        case .cliFailed(let message):
            return .other(short(message))
        case .service(let code, let message):
            return CostError.explain(code: code, message: message.isEmpty ? nil : short(message))
        }
    }

    private static func short(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "\u{2026}" : trimmed
    }
}
