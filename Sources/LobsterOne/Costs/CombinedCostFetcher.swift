import Foundation

/// Reads costs through several logins at once and adds them into one snapshot, for people
/// with no single login that sees every account. An account two logins both see counts
/// once, and a login that fails leaves the others standing.
nonisolated struct CombinedCostFetcher<Key: Hashable & Sendable>: CostFetching {
    struct Part: Sendable {
        let key: Key
        let fetcher: any CostFetching
        /// A reading of this login taken moments ago, used instead of paying for another.
        var reuse: CostSnapshot? = nil
    }

    let parts: [Part]
    /// Told what each login gave: a snapshot per login that answered, an error per one that didn't.
    let report: @Sendable (_ read: [Key: CostSnapshot], _ problems: [Key: CostError]) async -> Void

    /// How old a reused reading may be. Beyond this the login is asked again.
    static var reuseAge: TimeInterval { 3600 }

    func fetch(now: Date) async throws -> CostSnapshot {
        let month = CostMath.month(now)
        let results = await withTaskGroup(of: (Int, Result<CostSnapshot, CostError>).self) { group in
            for (index, part) in parts.enumerated() {
                group.addTask {
                    if let reuse = part.reuse, reuse.month == month,
                       now.timeIntervalSince(reuse.fetchedAt) < Self.reuseAge {
                        return (index, .success(reuse))
                    }
                    do {
                        return (index, .success(try await part.fetcher.fetch(now: now)))
                    } catch {
                        return (index, .failure(CostError.explain(error)))
                    }
                }
            }
            var all: [(Int, Result<CostSnapshot, CostError>)] = []
            for await result in group { all.append(result) }
            return all.sorted { $0.0 < $1.0 }
        }

        var read: [Key: CostSnapshot] = [:]
        var problems: [Key: CostError] = [:]
        var inOrder: [CostSnapshot] = []
        for (index, result) in results {
            switch result {
            case .success(let snapshot):
                read[parts[index].key] = snapshot
                inOrder.append(snapshot)
            case .failure(let error):
                problems[parts[index].key] = error
            }
        }
        await report(read, problems)
        guard let merged = CostMath.merge(inOrder) else {
            // Nothing answered: say why, starting with the first login.
            throw parts.first.flatMap { problems[$0.key] } ?? .notConnected
        }
        return merged
    }
}

extension CostMath {
    /// Several logins' readings as one. An account seen twice keeps the first figure (they
    /// are the same bill), names are pooled, and the result is as old as its oldest part.
    static func merge(_ snapshots: [CostSnapshot]) -> CostSnapshot? {
        guard let first = snapshots.first else { return nil }
        var thisMonth: [String: Double] = [:], lastMonth: [String: Double] = [:]
        var names: [String: String] = [:]
        for snapshot in snapshots {
            thisMonth.merge(snapshot.thisMonth) { kept, _ in kept }
            lastMonth.merge(snapshot.lastMonth) { kept, _ in kept }
            names.merge(snapshot.accountNames ?? [:]) { kept, _ in kept }
        }
        return CostSnapshot(fetchedAt: snapshots.map(\.fetchedAt).min() ?? first.fetchedAt,
                            currency: first.currency, month: first.month,
                            thisMonth: thisMonth, lastMonth: lastMonth,
                            estimated: snapshots.contains(where: \.estimated),
                            accountNames: names.isEmpty ? nil : names)
    }
}
