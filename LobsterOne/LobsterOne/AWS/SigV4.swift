import CryptoKit
import Foundation

/// AWS Signature Version 4, header form, written by hand so the app needs no
/// AWS SDK. Pure: the same inputs always give the same signature, which is
/// what lets the tests check it against AWS's published test suite.
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
nonisolated enum SigV4 {
    /// The intermediate steps are kept so tests can compare each one with the
    /// suite. `headers` and `canonicalRequest` hold the session token when
    /// there is one, so neither may be logged.
    struct Signature: Sendable {
        let canonicalRequest: String
        let stringToSign: String
        let signature: String
        let authorization: String
        /// Every header to send, Authorization included.
        let headers: [String: String]
    }

    /// Signs a request. `headers` are signed as given (plus `host`,
    /// `x-amz-date` and, with a session token, `x-amz-security-token`), so
    /// only pass headers whose value won't change on the way out.
    static func sign(method: String, url: URL, headers: [String: String], body: Data,
                     credentials: AWSCredentials, region: String, service: String,
                     date: Date) -> Signature {
        let amzDate = timestamp(date)
        let day = String(amzDate.prefix(8))

        var all = headers
        if !all.keys.contains(where: { $0.lowercased() == "host" }), let host = url.host {
            all["Host"] = url.port.map { "\(host):\($0)" } ?? host
        }
        all["X-Amz-Date"] = amzDate
        if let token = credentials.sessionToken {
            all["X-Amz-Security-Token"] = token
        }

        // Lowercase names, trimmed values with inner runs of spaces collapsed, sorted by name.
        var canonical: [String: String] = [:]
        for (name, value) in all {
            let squeezed = value.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            let key = name.lowercased()
            canonical[key] = canonical[key].map { "\($0),\(squeezed)" } ?? squeezed
        }
        let names = canonical.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(canonical[$0]!)\n" }.joined()

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            hex(SHA256.hash(data: body)),
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        all["Authorization"] = authorization
        return Signature(canonicalRequest: canonicalRequest, stringToSign: stringToSign,
                         signature: signature, authorization: authorization, headers: all)
    }

    /// A ready-to-send POST with the signature applied.
    static func signedPOST(url: URL, headers: [String: String], body: Data,
                           credentials: AWSCredentials, region: String, service: String,
                           date: Date) -> URLRequest {
        let signed = sign(method: "POST", url: url, headers: headers, body: body,
                          credentials: credentials, region: region, service: service, date: date)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in signed.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC, built from calendar parts so no shared
    /// DateFormatter is needed off the main thread.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    // MARK: - Canonical parts

    /// Each path segment URI-encoded once. Every endpoint this app calls posts
    /// to "/", so the double encoding non-S3 services ask for never comes up.
    private static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode($0.removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// RFC 3986: everything but A-Z a-z 0-9 - _ . ~ is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
