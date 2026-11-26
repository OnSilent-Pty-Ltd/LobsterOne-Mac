import Foundation

@MainActor
final class APIClient {
    private let baseURL: String
    private var apiKey: String?
    private let session: URLSession

    nonisolated init(baseURL: String = Constants.apiURL, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func setAPIKey(_ key: String) {
        self.apiKey = key
    }

    func buildRequest(path: String, method: String, bearerToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        } else if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    func fetchQuota() async throws -> QuotaResponse {
        let path = "/v1/usage/quota"
        let request = buildRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let error = APIError.httpError(statusCode: statusCode, path: path)
            DebugLog.shared.log("Failed \(path): \(error.displayMessage)")
            throw error
        }

        DebugLog.shared.log("OK \(path)")
        return try JSONDecoder().decode(QuotaResponse.self, from: data)
    }

    func fetchRealtime() async throws -> RealtimeResponse {
        let path = "/v1/usage/realtime"
        let request = buildRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let error = APIError.httpError(statusCode: statusCode, path: path)
            DebugLog.shared.log("Failed \(path): \(error.displayMessage)")
            throw error
        }

        DebugLog.shared.log("OK \(path)")
        return try JSONDecoder().decode(RealtimeResponse.self, from: data)
    }

    func fetchStatus() async throws -> StatusResponse {
        let path = "/v1/usage/status"
        var request = buildRequest(path: path, method: "GET")
        if let screensaver = ScreensaverReport.headerValue() {
            request.setValue(screensaver, forHTTPHeaderField: ScreensaverReport.headerName)
        }
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let error = APIError.httpError(statusCode: statusCode, path: path)
            DebugLog.shared.log("Failed \(path): \(error.displayMessage)")
            throw error
        }

        DebugLog.shared.log("OK \(path)")
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    func createAPIKey(label: String, bearerToken: String, sourceType: String? = nil) async throws -> CreateAPIKeyResponse {
        var request = buildRequest(path: "/v1/api-keys", method: "POST", bearerToken: bearerToken)
        request.httpBody = try JSONEncoder().encode(CreateAPIKeyRequest(label: label, sourceType: sourceType))

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        if httpResponse?.statusCode == 404 {
            throw APIError.userNotFound
        }

        guard let httpResponse, (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse?.statusCode ?? 0, path: "/v1/api-keys")
        }

        return try JSONDecoder().decode(CreateAPIKeyResponse.self, from: data)
    }

    func fetchInstances(bearerToken: String) async throws -> [Instance] {
        let path = "/v1/api-keys"
        let request = buildRequest(path: path, method: "GET", bearerToken: bearerToken)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: statusCode, path: path)
        }

        return try JSONDecoder().decode([Instance].self, from: data)
    }

    func renameInstance(id: String, label: String, bearerToken: String) async throws {
        let path = "/v1/api-keys/\(id)"
        var request = buildRequest(path: path, method: "PATCH", bearerToken: bearerToken)
        request.httpBody = try JSONEncoder().encode(["label": label])
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: statusCode, path: path)
        }
    }

    func mergeInstance(sourceId: String, targetId: String, bearerToken: String) async throws {
        let path = "/v1/api-keys/\(sourceId)/merge"
        var request = buildRequest(path: path, method: "POST", bearerToken: bearerToken)
        request.httpBody = try JSONEncoder().encode(["target_id": targetId])
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: statusCode, path: path)
        }
    }

    func revokeAPIKey(id: String) async throws {
        let path = "/v1/api-keys/\(id)"
        let request = buildRequest(path: path, method: "DELETE")
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: statusCode, path: path)
        }
    }

    private static let ingestBaseURL = Constants.ingestURL

    func fetchQuotaForInstance(apiKey: String, instanceId: String) async throws -> QuotaResponse {
        let path = "/v1/usage/quota?instance_id=\(instanceId)"
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: statusCode, path: "/v1/usage/quota")
        }

        return try JSONDecoder().decode(QuotaResponse.self, from: data)
    }

    func postQuotaSnapshot(_ payload: QuotaSnapshotPayload, apiKey: String) async throws {
        let path = "/v1/usage/quota"
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.shared.log("Failed POST \(path): HTTP \(statusCode)")
            throw APIError.httpError(statusCode: statusCode, path: path)
        }
    }

    func postCodexQuotaSnapshot(_ payload: CodexQuotaSnapshotPayload, apiKey: String) async throws {
        let path = "/v1/usage/quota"
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.shared.log("Failed POST \(path) (codex): HTTP \(statusCode)")
            throw APIError.httpError(statusCode: statusCode, path: path)
        }
    }

    func fetchNotificationCount() async throws -> NotificationCountResponse {
        let path = "/v1/notifications/count"
        let request = buildRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let error = APIError.httpError(statusCode: statusCode, path: path)
            DebugLog.shared.log("Failed \(path): \(error.displayMessage)")
            throw error
        }

        DebugLog.shared.log("OK \(path)")
        return try JSONDecoder().decode(NotificationCountResponse.self, from: data)
    }

    func markAllNotificationsRead() async throws {
        let path = "/v1/notifications/read-all"
        DebugLog.shared.log("Marking all notifications read")
        let request = buildRequest(path: path, method: "PUT")
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let error = APIError.httpError(statusCode: statusCode, path: path)
            DebugLog.shared.log("Failed \(path): \(error.displayMessage)")
            throw error
        }

        DebugLog.shared.log("OK \(path)")
    }

    /// Tell the backend where to push town invites (PUT) or to stop (DELETE).
    func sendAPNsDevice(_ device: APNsDeviceRequest, method: String) async throws {
        let path = "/v1/devices/apns"
        DebugLog.shared.log("\(method) \(path) (\(device.environment))")
        var request = buildRequest(path: path, method: method)
        request.httpBody = try JSONEncoder().encode(device)
        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let error = APIError.httpError(statusCode: statusCode, path: path)
            DebugLog.shared.log("Failed \(method) \(path): \(error.displayMessage)")
            throw error
        }

        DebugLog.shared.log("OK \(method) \(path)")
    }

    func fetchInstanceStatus(apiKey: String) async throws -> InstanceStatusResponse {
        let path = "/v1/instance/status"
        var request = URLRequest(url: URL(string: "\(Self.ingestBaseURL)\(path)")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(statusCode: statusCode, path: path)
        }

        return try JSONDecoder().decode(InstanceStatusResponse.self, from: data)
    }
}

enum APIError: Error, Equatable, LocalizedError {
    case httpError(statusCode: Int, path: String)
    case userNotFound

    var displayMessage: String {
        switch self {
        case .httpError(let statusCode, let path):
            let reason: String
            switch statusCode {
            case 401: reason = "Unauthorized"
            case 403: reason = "Forbidden"
            case 404: reason = "Not Found"
            case 429: reason = "Rate Limited"
            case 500...599: reason = "Server Error"
            default: reason = "HTTP \(statusCode)"
            }
            return "\(statusCode) \(reason) on \(path)"
        case .userNotFound:
            return "User not found"
        }
    }

    var errorDescription: String? { displayMessage }
}
