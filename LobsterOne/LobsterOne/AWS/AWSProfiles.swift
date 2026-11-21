import Foundation

/// Reads `~/.aws/config` and `~/.aws/credentials`. Ported from TigerSoup's
/// AWSConfigReader. In `config`, non-default sections are written
/// `[profile NAME]` and the default is `[default]`; in `credentials`,
/// sections are bare `[NAME]`.
nonisolated enum AWSProfiles {
    static func profileNames(configContents: String, credentialsContents: String) -> [String] {
        var names = Set<String>()

        for line in configContents.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { continue }
            let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner == "default" {
                names.insert("default")
            } else if inner.hasPrefix("profile ") {
                names.insert(String(inner.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        for line in credentialsContents.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { continue }
            names.insert(String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
        }

        return names.filter { !$0.isEmpty }.sorted()
    }

    /// Reads the standard files from disk (missing files → empty string).
    static func profileNamesFromDisk(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let (config, creds) = files(home: home)
        return profileNames(configContents: config, credentialsContents: creds)
    }

    /// How a profile gets its login, judged from setting names only (never
    /// values other than `source_profile`). Decides whether we read keys
    /// ourselves or ask the CLI, and explains failures.
    enum ProfileKind: Equatable, Sendable {
        case sso
        case needsMFA
        case assumeRole(sourceProfile: String?)
        case process
        case staticKeys
        case empty
    }

    static func profileKind(_ name: String, configContents: String, credentialsContents: String) -> ProfileKind {
        let config = settings(of: configHeaders(name), in: configContents)
        let creds = settings(of: [name], in: credentialsContents)
        let all = config.merging(creds) { a, _ in a }
        if all["sso_session"] != nil || all["sso_start_url"] != nil { return .sso }
        if all["mfa_serial"] != nil { return .needsMFA }
        if all["role_arn"] != nil { return .assumeRole(sourceProfile: all["source_profile"]) }
        if all["credential_process"] != nil { return .process }
        if all["aws_access_key_id"] != nil { return .staticKeys }
        return .empty
    }

    static func profileKindFromDisk(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProfileKind {
        let (config, creds) = files(home: home)
        return profileKind(name, configContents: config, credentialsContents: creds)
    }

    /// Long-lived keys written into the files. The credentials file wins over
    /// config, the same order the AWS CLI uses. Nil unless both the id and the
    /// secret are present.
    static func staticKeys(_ name: String, configContents: String, credentialsContents: String) -> AWSCredentials? {
        let creds = settings(of: [name], in: credentialsContents)
        let config = settings(of: configHeaders(name), in: configContents)
        let all = creds.merging(config) { a, _ in a }
        guard let id = all["aws_access_key_id"], !id.isEmpty,
              let secret = all["aws_secret_access_key"], !secret.isEmpty else { return nil }
        let token = all["aws_session_token"].flatMap { $0.isEmpty ? nil : $0 }
        return AWSCredentials(accessKeyId: id, secretAccessKey: secret, sessionToken: token)
    }

    static func staticKeysFromDisk(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AWSCredentials? {
        let (config, creds) = files(home: home)
        return staticKeys(name, configContents: config, credentialsContents: creds)
    }

    /// Names we are willing to pass to the CLI: letters, digits and `._-@+`,
    /// up to 64 characters, not starting with `-` (which would read as a flag).
    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy { allowedNameCharacters.contains($0) }
    }

    private static let allowedNameCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-@+")

    /// Account id → profile name, read from what the profiles say about themselves: an SSO
    /// profile's `sso_account_id`, or the account in a role profile's `role_arn`. Gives an
    /// account a readable name when AWS Organizations won't supply one. No secrets involved.
    static func accountNames(configContents: String, credentialsContents: String) -> [String: String] {
        var names: [String: String] = [:]
        for profile in profileNames(configContents: configContents, credentialsContents: credentialsContents) {
            let all = settings(of: configHeaders(profile), in: configContents)
            guard let id = all["sso_account_id"] ?? all["role_arn"].flatMap(accountId(inARN:)),
                  names[id] == nil else { continue }
            names[id] = profile
        }
        return names
    }

    static func accountNamesFromDisk(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        let f = files(home: home)
        return accountNames(configContents: f.config, credentialsContents: f.credentials)
    }

    /// The twelve-digit account in `arn:aws:iam::123456789012:role/name`.
    static func accountId(inARN arn: String) -> String? {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[4].count == 12, parts[4].allSatisfy(\.isNumber) else { return nil }
        return String(parts[4])
    }

    // MARK: - Parsing

    private static func configHeaders(_ name: String) -> [String] {
        name == "default" ? ["default"] : ["profile \(name)", name]
    }

    private static func files(home: URL) -> (config: String, credentials: String) {
        let config = (try? String(contentsOf: home.appending(path: ".aws/config"), encoding: .utf8)) ?? ""
        let creds = (try? String(contentsOf: home.appending(path: ".aws/credentials"), encoding: .utf8)) ?? ""
        return (config, creds)
    }

    /// Key/value settings of the first section whose header matches one of `headers`.
    private static func settings(of headers: [String], in contents: String) -> [String: String] {
        var result: [String: String] = [:]
        var inSection = false
        for line in contents.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]") {
                let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if inSection { break }
                inSection = headers.contains(inner)
                continue
            }
            guard inSection, !t.hasPrefix("#"), !t.hasPrefix(";"),
                  let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            result[key] = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
