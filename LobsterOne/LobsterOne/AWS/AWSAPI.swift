import Foundation

/// One account's spend in one month, as Cost Explorer returns it.
nonisolated struct AWSCostRow: Equatable, Sendable {
    let periodStart: String
    let account: String
    let amount: Double
    let unit: String
    let estimated: Bool
}

/// The three AWS calls the app makes, signed by hand with SigV4 and sent as
/// plain JSON (or a form, for STS). No AWS SDK: it made TigerSoup's CI five
/// times slower and doubled the app for these few calls.
nonisolated struct AWSAPI: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Each Cost Explorer request bills the user $0.01, so a runaway
    /// pagination loop must stop somewhere.
    static let maxCostPages = 20
    static let maxAccountPages = 200

    private let credentials: @Sendable () async throws -> AWSCredentials
    private let credentialsRejected: @Sendable () async -> Void
    private let transport: Transport
    private let now: @Sendable () -> Date

    init(credentials: @escaping @Sendable () async throws -> AWSCredentials,
         credentialsRejected: @escaping @Sendable () async -> Void = {},
         transport: @escaping Transport = AWSAPI.urlSession(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.credentialsRejected = credentialsRejected
        self.transport = transport
        self.now = now
    }

    /// Resolves keys through `provider` on every call (it caches), and drops
    /// its cache when AWS rejects them so the next call fetches fresh ones.
    init(provider: AWSCredentialProvider, connection: AWSConnection,
         transport: @escaping Transport = AWSAPI.urlSession(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(credentials: { try await provider.credentials(for: connection) },
                  credentialsRejected: { await provider.invalidate(connection) },
                  transport: transport, now: now)
    }

    static func urlSession(_ session: URLSession = .shared) -> Transport {
        { request in try await session.data(for: request) }
    }

    // MARK: - Cost Explorer

    /// Monthly unblended cost per linked account from `start` (inclusive) to
    /// `end` (exclusive), both `yyyy-MM-dd`. Follows NextPageToken.
    ///
    /// Each request costs the user $0.01 (AWS bills every Cost Explorer API
    /// call), so call it on a slow schedule, never in a loop.
    func getCostAndUsage(start: String, end: String) async throws -> [AWSCostRow] {
        // A malformed date would still be billed, then rejected.
        guard Self.isDay(start), Self.isDay(end) else {
            throw AWSClientError.service(code: "ValidationException", message: "Dates must be yyyy-MM-dd.")
        }
        var rows: [AWSCostRow] = []
        var token: String?
        var pages = 0
        repeat {
            var body: [String: Any] = [
                "Granularity": "MONTHLY",
                "Metrics": ["UnblendedCost"],
                "GroupBy": [["Type": "DIMENSION", "Key": "LINKED_ACCOUNT"]],
                "TimePeriod": ["Start": start, "End": end],
            ]
            if let token { body["NextPageToken"] = token }
            let data = try await postJSON(Self.costExplorer, body: body)
            let page = try Self.parseCostPage(data)
            rows += page.rows
            token = page.next
            pages += 1
        } while token != nil && pages < Self.maxCostPages
        return rows
    }

    static func parseCostPage(_ data: Data) throws -> (rows: [AWSCostRow], next: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw unreadable("Cost Explorer")
        }
        var rows: [AWSCostRow] = []
        for period in json["ResultsByTime"] as? [[String: Any]] ?? [] {
            let start = (period["TimePeriod"] as? [String: Any])?["Start"] as? String ?? ""
            let estimated = period["Estimated"] as? Bool ?? false
            for group in period["Groups"] as? [[String: Any]] ?? [] {
                guard let account = (group["Keys"] as? [String])?.first,
                      let metric = (group["Metrics"] as? [String: Any])?["UnblendedCost"] as? [String: Any]
                else { continue }
                // Amounts come as strings, e.g. "39.1603300457".
                let amount = (metric["Amount"] as? String).flatMap(Double.init) ?? 0
                rows.append(AWSCostRow(periodStart: start, account: account, amount: amount,
                                       unit: metric["Unit"] as? String ?? "USD", estimated: estimated))
            }
        }
        return (rows, nonEmpty(json["NextPageToken"]))
    }

    // MARK: - Organizations

    /// Account id → name for every account in the organization. Free. Only
    /// works from the management account (or a delegated admin); elsewhere it
    /// throws `.accessDenied` or `.service(code: "AWSOrganizationsNotInUseException", …)`.
    func listAccountNames() async throws -> [String: String] {
        var names: [String: String] = [:]
        var token: String?
        var pages = 0
        repeat {
            let body: [String: Any] = token.map { ["NextToken": $0] } ?? [:]
            let data = try await postJSON(Self.organizations, body: body)
            let page = try Self.parseAccountsPage(data)
            names.merge(page.names) { _, new in new }
            token = page.next
            pages += 1
        } while token != nil && pages < Self.maxAccountPages
        return names
    }

    /// The id of the organization's management account, the one login that can read every
    /// account's costs and names. Nil when the account isn't in an organization, so it is the
    /// only account there is. Free, and callable from any account in the organization.
    func managementAccountId() async throws -> String? {
        do {
            return try Self.parseOrganization(try await postJSON(Self.describeOrganization, body: [:]))
        } catch AWSClientError.service(code: "AWSOrganizationsNotInUseException", _) {
            return nil
        }
    }

    static func parseOrganization(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = json["Organization"] as? [String: Any],
              let id = nonEmpty(organization["MasterAccountId"]) else {
            throw unreadable("Organizations")
        }
        return id
    }

    static func parseAccountsPage(_ data: Data) throws -> (names: [String: String], next: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw unreadable("Organizations")
        }
        var names: [String: String] = [:]
        for account in json["Accounts"] as? [[String: Any]] ?? [] {
            if let id = account["Id"] as? String, let name = account["Name"] as? String {
                names[id] = name
            }
        }
        return (names, nonEmpty(json["NextToken"]))
    }

    // MARK: - STS

    /// Who these keys belong to. Free and needs no permissions, so it's the
    /// honest "does this login work at all" check behind Test connection.
    func callerIdentity() async throws -> (account: String, arn: String) {
        let body = Data("Action=GetCallerIdentity&Version=2011-06-15".utf8)
        let data = try await post(Self.sts, body: body, headers: [
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "Accept": "application/json",
        ])
        return try Self.parseCallerIdentity(data)
    }

    /// STS is a query-protocol API: it answers JSON when asked with
    /// `Accept: application/json`, XML otherwise. Both are read.
    static func parseCallerIdentity(_ data: Data) throws -> (account: String, arn: String) {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let result = (json["GetCallerIdentityResponse"] as? [String: Any])?["GetCallerIdentityResult"] as? [String: Any]
            if let account = result?["Account"] as? String, let arn = result?["Arn"] as? String {
                return (account, arn)
            }
        } else {
            let xml = String(decoding: data, as: UTF8.self)
            if let account = xmlValue("Account", in: xml), let arn = xmlValue("Arn", in: xml) {
                return (account, arn)
            }
        }
        throw unreadable("STS")
    }

    // MARK: - Errors

    /// Reads AWS's error code and message from a failed response, whichever of
    /// the shapes it uses: JSON `__type`/`message` (Cost Explorer,
    /// Organizations), JSON or XML `Error.Code`/`Message` (STS), or only the
    /// `x-amzn-ErrorType` header.
    static func error(status: Int, body: Data, errorTypeHeader: String? = nil) -> AWSClientError {
        var code = ""
        var message = ""
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let inner = json["Error"] as? [String: Any] ?? json
            code = (json["__type"] as? String) ?? (inner["Code"] as? String) ?? (inner["code"] as? String) ?? ""
            message = (inner["message"] as? String) ?? (inner["Message"] as? String) ?? ""
        } else {
            let xml = String(decoding: body, as: UTF8.self)
            code = xmlValue("Code", in: xml) ?? ""
            message = xmlValue("Message", in: xml) ?? ""
        }
        if code.isEmpty, let header = errorTypeHeader { code = header }
        code = cleanCode(code)
        if code.isEmpty {
            return .service(code: "HTTP \(status)", message: message.isEmpty
                            ? String(String(decoding: body.prefix(300), as: UTF8.self)) : message)
        }
        return classify(code: code, message: message)
    }

    /// Split out so the mapping can be tested on its own. Mirrors TigerSoup's
    /// CostExplorerFetcher.explain.
    static func classify(code: String, message: String) -> AWSClientError {
        switch code {
        case "AccessDeniedException", "AccessDenied":
            // AWS's wording when Cost Explorer has never been opened.
            if message.lowercased().contains("not enabled for cost explorer") { return .costExplorerNotEnabled }
            return .accessDenied(message: message)
        case "DataUnavailableException":
            return .costExplorerNotEnabled
        case "ExpiredToken", "ExpiredTokenException", "UnrecognizedClientException",
             "InvalidClientTokenId", "SignatureDoesNotMatch", "InvalidSignatureException":
            return .credentialsInvalid
        default:
            return .service(code: code, message: message)
        }
    }

    /// `com.amazon.coral.service#UnrecognizedClientException` → `UnrecognizedClientException`;
    /// the header form `Code:http://internal.amazon.com/…` → `Code`.
    static func cleanCode(_ raw: String) -> String {
        var code = Substring(raw.trimmingCharacters(in: .whitespaces))
        if let hash = code.lastIndex(of: "#") { code = code[code.index(after: hash)...] }
        if let colon = code.firstIndex(of: ":") { code = code[..<colon] }
        return String(code)
    }

    // MARK: - Sending

    private static let costExplorer = Endpoint(
        url: URL(string: "https://ce.us-east-1.amazonaws.com/")!, region: "us-east-1", service: "ce",
        target: "AWSInsightsIndexService.GetCostAndUsage")
    private static let organizations = Endpoint(
        url: URL(string: "https://organizations.us-east-1.amazonaws.com/")!, region: "us-east-1",
        service: "organizations", target: "AWSOrganizationsV20161128.ListAccounts")
    private static let describeOrganization = Endpoint(
        url: URL(string: "https://organizations.us-east-1.amazonaws.com/")!, region: "us-east-1",
        service: "organizations", target: "AWSOrganizationsV20161128.DescribeOrganization")
    private static let sts = Endpoint(
        url: URL(string: "https://sts.amazonaws.com/")!, region: "us-east-1", service: "sts", target: nil)

    private struct Endpoint: Sendable {
        let url: URL
        let region: String
        let service: String
        let target: String?
    }

    private func postJSON(_ endpoint: Endpoint, body: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var headers = ["Content-Type": "application/x-amz-json-1.1"]
        if let target = endpoint.target { headers["X-Amz-Target"] = target }
        return try await post(endpoint, body: data, headers: headers)
    }

    private func post(_ endpoint: Endpoint, body: Data, headers: [String: String]) async throws -> Data {
        let keys: AWSCredentials
        do {
            keys = try await credentials()
        } catch let error as AWSClientError {
            throw error
        } catch {
            throw AWSClientError.notConnected
        }

        var request = SigV4.signedPOST(url: endpoint.url, headers: headers, body: body, credentials: keys,
                                       region: endpoint.region, service: endpoint.service, date: now())
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AWSClientError.network
        }
        guard let http = response as? HTTPURLResponse else { throw AWSClientError.network }
        guard (200..<300).contains(http.statusCode) else {
            let error = Self.error(status: http.statusCode, body: data,
                                   errorTypeHeader: http.value(forHTTPHeaderField: "x-amzn-ErrorType"))
            if error == .credentialsInvalid { await credentialsRejected() }
            throw error
        }
        return data
    }

    // MARK: - Helpers

    private static func isDay(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.map(\.count) == [4, 2, 2]
            && parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func unreadable(_ service: String) -> AWSClientError {
        .service(code: "UnreadableResponse", message: "\(service) sent a response LobsterOne can't read.")
    }

    /// The text of the first `<tag>…</tag>`. Enough for STS's flat responses.
    private static func xmlValue(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
