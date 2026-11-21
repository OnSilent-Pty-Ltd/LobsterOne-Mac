import Foundation

enum ClientPolicyLevel: String, Decodable {
    case ok
    case soft
    case block
}

struct ClientPolicy: Decodable, Equatable {
    let level: ClientPolicyLevel
    let message: String?
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case level
        case message
        case downloadUrl = "download_url"
    }

    init(level: ClientPolicyLevel, message: String? = nil, downloadUrl: String? = nil) {
        self.level = level
        self.message = message
        self.downloadUrl = downloadUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Forward-compatible level decode: anything we don't recognise → .ok
        // so old clients never get stuck because of a future server-side level.
        let raw = try container.decode(String.self, forKey: .level)
        self.level = ClientPolicyLevel(rawValue: raw) ?? .ok
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.downloadUrl = try container.decodeIfPresent(String.self, forKey: .downloadUrl)
    }

    static let okDefault = ClientPolicy(level: .ok)
}
