import Combine
import Foundation

/// Holds the current backend-supplied client policy and publishes changes.
/// Persists the latest policy to `UserDefaults` so the app boots into the
/// correct enforcement state even before the first poll completes.
@MainActor
final class ClientPolicyService: ObservableObject {
    @Published private(set) var current: ClientPolicy

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = Constants.clientPolicyDefaultsKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.current = Self.hydrate(from: defaults, key: storageKey) ?? .okDefault
    }

    /// Apply a new policy from a poll response. `nil` (the field was absent)
    /// is treated as `.ok`.
    func update(_ policy: ClientPolicy?) {
        let next = policy ?? .okDefault
        guard next != current else { return }
        current = next
        persist(next)
    }

    private func persist(_ policy: ClientPolicy) {
        guard let data = try? JSONEncoder().encode(PersistedPolicy(policy: policy)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func hydrate(from defaults: UserDefaults, key: String) -> ClientPolicy? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return (try? JSONDecoder().decode(PersistedPolicy.self, from: data))?.policy
    }
}

/// Codable wrapper so we can persist `ClientPolicy` (whose `init(from:)` is
/// defined for *server-side* JSON shape) to/from defaults using the same
/// shape.
private struct PersistedPolicy: Codable {
    let level: String
    let message: String?
    let downloadUrl: String?

    init(policy: ClientPolicy) {
        self.level = policy.level.rawValue
        self.message = policy.message
        self.downloadUrl = policy.downloadUrl
    }

    var policy: ClientPolicy {
        ClientPolicy(
            level: ClientPolicyLevel(rawValue: level) ?? .ok,
            message: message,
            downloadUrl: downloadUrl
        )
    }
}
