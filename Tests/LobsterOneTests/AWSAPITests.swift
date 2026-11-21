import Testing
import Foundation
@testable import LobsterOne

/// Answers requests from a queue of canned responses and keeps what was sent.
private final class FakeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var responses: [(Int, String, [String: String])]
    private let failure: Error?

    init(_ responses: [(Int, String, [String: String])] = [], failure: Error? = nil) {
        self.responses = responses
        self.failure = failure
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    var transport: AWSAPI.Transport {
        { request in try self.send(request) }
    }

    private func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        try lock.withLock {
            _requests.append(request)
            if let failure { throw failure }
            let (status, body, headers) = responses.isEmpty ? (200, "{}", [:]) : responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _set = false
    var isSet: Bool { lock.withLock { _set } }
    func set() { lock.withLock { _set = true } }
}

private let keys = AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "tok")
private let fixedDate = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!

private func api(_ fake: FakeTransport, rejected: Flag = Flag()) -> AWSAPI {
    AWSAPI(credentials: { keys }, credentialsRejected: { rejected.set() }, transport: fake.transport, now: { fixedDate })
}

private func bodyJSON(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

private let costPage1 = """
{"GroupDefinitions":[{"Key":"LINKED_ACCOUNT","Type":"DIMENSION"}],
 "ResultsByTime":[
  {"Estimated":false,"TimePeriod":{"Start":"2026-10-01","End":"2026-11-01"},"Total":{},
   "Groups":[{"Keys":["111111111111"],"Metrics":{"UnblendedCost":{"Amount":"39.1603300457","Unit":"USD"}}},
             {"Keys":["222222222222"],"Metrics":{"UnblendedCost":{"Amount":"0.13","Unit":"USD"}}}]}],
 "NextPageToken":"page2",
 "DimensionValueAttributes":[{"Value":"111111111111","Attributes":{"description":"Main"}}]}
"""

private let costPage2 = """
{"ResultsByTime":[
  {"Estimated":true,"TimePeriod":{"Start":"2026-11-01","End":"2026-11-18"},"Total":{},
   "Groups":[{"Keys":["111111111111"],"Metrics":{"UnblendedCost":{"Amount":"12.5","Unit":"USD"}}},
             {"Keys":[],"Metrics":{}}]}]}
"""

// MARK: - Cost Explorer

@Test func costRequestIsSignedForCostExplorer() async throws {
    let fake = FakeTransport([(200, costPage2, [:])])
    _ = try await api(fake).getCostAndUsage(start: "2026-10-01", end: "2026-11-18")

    let request = try #require(fake.requests.first)
    #expect(request.url?.absoluteString == "https://ce.us-east-1.amazonaws.com/")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "AWSInsightsIndexService.GetCostAndUsage")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.1")
    #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20261118T120000Z")
    #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "tok")
    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
    #expect(auth.contains("Credential=AKIDEXAMPLE/20261118/us-east-1/ce/aws4_request"))
    #expect(auth.contains("SignedHeaders=content-type;host;x-amz-date;x-amz-security-token;x-amz-target"))

    let body = bodyJSON(request)
    #expect(body["Granularity"] as? String == "MONTHLY")
    #expect(body["Metrics"] as? [String] == ["UnblendedCost"])
    #expect(body["GroupBy"] as? [[String: String]] == [["Type": "DIMENSION", "Key": "LINKED_ACCOUNT"]])
    #expect(body["TimePeriod"] as? [String: String] == ["Start": "2026-10-01", "End": "2026-11-18"])
    #expect(body["NextPageToken"] == nil)
}

@Test func costFollowsNextPageToken() async throws {
    let fake = FakeTransport([(200, costPage1, [:]), (200, costPage2, [:])])
    let rows = try await api(fake).getCostAndUsage(start: "2026-10-01", end: "2026-11-18")
    #expect(rows == [
        AWSCostRow(periodStart: "2026-10-01", account: "111111111111", amount: 39.1603300457, unit: "USD", estimated: false),
        AWSCostRow(periodStart: "2026-10-01", account: "222222222222", amount: 0.13, unit: "USD", estimated: false),
        AWSCostRow(periodStart: "2026-11-01", account: "111111111111", amount: 12.5, unit: "USD", estimated: true),
    ])
    #expect(fake.requests.count == 2)
    #expect(bodyJSON(fake.requests[1])["NextPageToken"] as? String == "page2")
}

@Test func costPaginationStopsAtCap() async throws {
    // A token that never ends must not keep billing the user.
    let looping = #"{"ResultsByTime":[],"NextPageToken":"again"}"#
    let fake = FakeTransport(Array(repeating: (200, looping, [:]), count: 30))
    _ = try await api(fake).getCostAndUsage(start: "2026-10-01", end: "2026-11-01")
    #expect(fake.requests.count == AWSAPI.maxCostPages)
}

@Test func costRejectsMalformedDatesWithoutCalling() async {
    let fake = FakeTransport()
    await #expect(throws: AWSClientError.self) { try await api(fake).getCostAndUsage(start: "2026-1-01", end: "2026-11-01") }
    #expect(fake.requests.isEmpty)
}

@Test func costNotEnabledIsRecognised() async {
    let fake = FakeTransport([(400, #"{"__type":"AccessDeniedException","Message":"User not enabled for cost explorer access"}"#, [:])])
    await #expect(throws: AWSClientError.costExplorerNotEnabled) {
        try await api(fake).getCostAndUsage(start: "2026-10-01", end: "2026-11-01")
    }
}

// MARK: - Organizations

@Test func listAccountsPaginatesAndSignsForOrganizations() async throws {
    let page1 = #"{"Accounts":[{"Id":"111111111111","Name":"Management account","State":"ACTIVE"}],"NextToken":"n2"}"#
    let page2 = #"{"Accounts":[{"Id":"222222222222","Name":"Production Account"},{"Id":"333"}]}"#
    let fake = FakeTransport([(200, page1, [:]), (200, page2, [:])])
    let names = try await api(fake).listAccountNames()
    #expect(names == ["111111111111": "Management account", "222222222222": "Production Account"])

    let first = fake.requests[0]
    #expect(first.url?.absoluteString == "https://organizations.us-east-1.amazonaws.com/")
    #expect(first.value(forHTTPHeaderField: "X-Amz-Target") == "AWSOrganizationsV20161128.ListAccounts")
    #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.1")
    #expect(first.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/organizations/aws4_request") == true)
    #expect(String(decoding: first.httpBody ?? Data(), as: UTF8.self) == "{}")
    #expect(bodyJSON(fake.requests[1])["NextToken"] as? String == "n2")
}

@Test func listAccountsOutsideOrganization() async {
    let body = #"{"__type":"AWSOrganizationsNotInUseException","Message":"Your account is not a member of an organization."}"#
    let fake = FakeTransport([(400, body, [:])])
    await #expect(throws: AWSClientError.service(code: "AWSOrganizationsNotInUseException",
                                                 message: "Your account is not a member of an organization.")) {
        try await api(fake).listAccountNames()
    }
}

// MARK: - STS

@Test func callerIdentityRequestIsAQueryPOST() async throws {
    let json = #"{"GetCallerIdentityResponse":{"GetCallerIdentityResult":{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/Alice","UserId":"AIDA"},"ResponseMetadata":{"RequestId":"r"}}}"#
    let fake = FakeTransport([(200, json, [:])])
    let who = try await api(fake).callerIdentity()
    #expect(who.account == "123456789012")
    #expect(who.arn == "arn:aws:iam::123456789012:user/Alice")

    let request = try #require(fake.requests.first)
    #expect(request.url?.absoluteString == "https://sts.amazonaws.com/")
    #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "Action=GetCallerIdentity&Version=2011-06-15")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/sts/aws4_request") == true)
}

@Test func callerIdentityReadsXML() throws {
    // The documented sample response.
    let xml = """
    <GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
      <GetCallerIdentityResult>
      <Arn>arn:aws:iam::123456789012:user/Alice</Arn>
      <UserId>AIDACKCEVSQ6C2EXAMPLE</UserId>
      <Account>123456789012</Account>
      </GetCallerIdentityResult>
    </GetCallerIdentityResponse>
    """
    let who = try AWSAPI.parseCallerIdentity(Data(xml.utf8))
    #expect(who.account == "123456789012")
    #expect(who.arn == "arn:aws:iam::123456789012:user/Alice")
}

@Test func callerIdentityGarbageIsUnreadable() {
    #expect(throws: AWSClientError.self) { try AWSAPI.parseCallerIdentity(Data("<html>".utf8)) }
}

// MARK: - Error mapping

@Test func errorMappingByCode() {
    #expect(AWSAPI.classify(code: "AccessDeniedException", message: "User: x is not authorized") == .accessDenied(message: "User: x is not authorized"))
    #expect(AWSAPI.classify(code: "AccessDeniedException", message: "User not enabled for cost explorer access") == .costExplorerNotEnabled)
    #expect(AWSAPI.classify(code: "DataUnavailableException", message: "") == .costExplorerNotEnabled)
    for code in ["ExpiredToken", "ExpiredTokenException", "UnrecognizedClientException",
                 "InvalidClientTokenId", "SignatureDoesNotMatch", "InvalidSignatureException"] {
        #expect(AWSAPI.classify(code: code, message: "m") == .credentialsInvalid, "\(code)")
    }
    #expect(AWSAPI.classify(code: "LimitExceededException", message: "slow down") == .service(code: "LimitExceededException", message: "slow down"))
}

@Test func errorMappingReadsEveryShape() {
    // JSON 1.1 with the namespace prefix, lower-case message.
    let coral = Data(#"{"__type":"com.amazon.coral.service#UnrecognizedClientException","message":"The security token included in the request is invalid."}"#.utf8)
    #expect(AWSAPI.error(status: 400, body: coral) == .credentialsInvalid)

    // STS query-protocol XML.
    let xml = Data("""
    <ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
      <Error><Type>Sender</Type><Code>ExpiredToken</Code><Message>The security token included in the request is expired</Message></Error>
    </ErrorResponse>
    """.utf8)
    #expect(AWSAPI.error(status: 403, body: xml) == .credentialsInvalid)

    // STS JSON.
    let stsJSON = Data(#"{"Error":{"Code":"AccessDenied","Message":"nope","Type":"Sender"}}"#.utf8)
    #expect(AWSAPI.error(status: 403, body: stsJSON) == .accessDenied(message: "nope"))

    // Only the header.
    #expect(AWSAPI.error(status: 400, body: Data(), errorTypeHeader: "InvalidSignatureException:http://internal.amazon.com/coral/com.amazon.coral.service/")
            == .credentialsInvalid)

    // Nothing to go on.
    #expect(AWSAPI.error(status: 502, body: Data("Bad Gateway".utf8)) == .service(code: "HTTP 502", message: "Bad Gateway"))
}

@Test func cleanCodeStripsPrefixAndSuffix() {
    #expect(AWSAPI.cleanCode("com.amazonaws.ce#DataUnavailableException") == "DataUnavailableException")
    #expect(AWSAPI.cleanCode("AccessDeniedException:http://internal.amazon.com/") == "AccessDeniedException")
    #expect(AWSAPI.cleanCode("ExpiredToken") == "ExpiredToken")
}

@Test func rejectedCredentialsDropTheCache() async {
    let fake = FakeTransport([(400, #"{"__type":"ExpiredTokenException","message":"expired"}"#, [:])])
    let rejected = Flag()
    await #expect(throws: AWSClientError.credentialsInvalid) { try await api(fake, rejected: rejected).listAccountNames() }
    #expect(rejected.isSet)
}

@Test func transportFailureIsNetwork() async {
    let fake = FakeTransport(failure: URLError(.notConnectedToInternet))
    await #expect(throws: AWSClientError.network) { try await api(fake).callerIdentity() }
}

@Test func credentialErrorsPassThrough() async {
    let fake = FakeTransport()
    let client = AWSAPI(credentials: { throw AWSClientError.needsSignIn(profile: "org") }, transport: fake.transport)
    await #expect(throws: AWSClientError.needsSignIn(profile: "org")) { try await client.callerIdentity() }
    #expect(fake.requests.isEmpty)
}
