import Testing
import Foundation
@testable import LobsterOne

// Expected values are AWS's SigV4 test suite as kept in awslabs/aws-c-auth
// (tests/aws-signing-test-suite/v4/<case>/header-*.txt), copied verbatim.

private let suiteKeys = AWSCredentials(accessKeyId: "AKIDEXAMPLE",
                                       secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
private let suiteDate = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
private let suiteURL = URL(string: "https://example.amazonaws.com/")!

private func suiteSign(_ method: String, headers: [String: String] = [:], body: String = "",
                       keys: AWSCredentials = suiteKeys) -> SigV4.Signature {
    SigV4.sign(method: method, url: suiteURL, headers: headers, body: Data(body.utf8),
               credentials: keys, region: "us-east-1", service: "service", date: suiteDate)
}

@Test func sigV4GetVanilla() {
    let s = suiteSign("GET")
    #expect(s.canonicalRequest == """
    GET
    /

    host:example.amazonaws.com
    x-amz-date:20150830T123600Z

    host;x-amz-date
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    """)
    #expect(s.stringToSign == """
    AWS4-HMAC-SHA256
    20150830T123600Z
    20150830/us-east-1/service/aws4_request
    bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63
    """)
    #expect(s.signature == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    #expect(s.authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
}

@Test func sigV4PostVanilla() {
    let s = suiteSign("POST")
    #expect(s.stringToSign.hasSuffix("553f88c9e4d10fc9e109e2aeb65f030801b70c2f6468faca261d401ae622fc87"))
    #expect(s.signature == "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")
}

@Test func sigV4PostFormBody() {
    // This case signs the body, so the suite also sends x-amz-content-sha256.
    let s = suiteSign("POST", headers: [
        "Content-Type": "application/x-www-form-urlencoded",
        "Content-Length": "13",
        "X-Amz-Content-Sha256": "9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e",
    ], body: "Param1=value1")
    #expect(s.canonicalRequest == """
    POST
    /

    content-length:13
    content-type:application/x-www-form-urlencoded
    host:example.amazonaws.com
    x-amz-content-sha256:9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e
    x-amz-date:20150830T123600Z

    content-length;content-type;host;x-amz-content-sha256;x-amz-date
    9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e
    """)
    #expect(s.stringToSign.hasSuffix("b1edd1d03544c25390e32085d55b57acc9a3961bb59415ff86c45c3d89d16cfb"))
    #expect(s.signature == "d3875051da38690788ef43de4db0d8f280229d82040bfac253562e56c3f20e0b")
}

@Test func sigV4SignsSessionToken() {
    // post-sts-header-before: the token is a signed header.
    let token = "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA=="
    let keys = AWSCredentials(accessKeyId: "AKIDEXAMPLE",
                              secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: token)
    let s = suiteSign("POST", keys: keys)
    #expect(s.canonicalRequest.contains("\nhost;x-amz-date;x-amz-security-token\n"))
    #expect(s.stringToSign.hasSuffix("c237e1b440d4c63c32ca95b5b99481081cb7b13c7e40434868e71567c1a882f6"))
    #expect(s.signature == "85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead")
    #expect(s.headers["X-Amz-Security-Token"] == token)
}

@Test func sigV4SignedPOSTCarriesHeadersAndBody() {
    let body = Data("{}".utf8)
    let request = SigV4.signedPOST(url: URL(string: "https://ce.us-east-1.amazonaws.com/")!,
                                   headers: ["Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": "T.Op"],
                                   body: body, credentials: suiteKeys, region: "us-east-1", service: "ce",
                                   date: suiteDate)
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == body)
    #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
    #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == nil)
    let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
    #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/ce/aws4_request, "))
    #expect(auth.contains("SignedHeaders=content-type;host;x-amz-date;x-amz-target, "))
}

@Test func sigV4TimestampIsUTC() {
    #expect(SigV4.timestamp(Date(timeIntervalSince1970: 0)) == "19700101T000000Z")
    #expect(SigV4.timestamp(suiteDate) == "20150830T123600Z")
}
