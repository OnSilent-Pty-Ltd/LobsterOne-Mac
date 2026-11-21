import Testing
import Foundation
@testable import LobsterOne

// The first three are TigerSoup's AWSConfigReaderTests, moved to swift-testing.

@Test func awsProfilesParsesConfigProfiles() {
    let config = """
    [default]
    region = us-east-1

    [profile org-admin]
    sso_start_url = https://x.awsapps.com/start

    [profile dev]
    region = eu-west-1
    """
    let creds = """
    [legacy-user]
    aws_access_key_id = AKID
    """
    let names = AWSProfiles.profileNames(configContents: config, credentialsContents: creds)
    #expect(names == ["default", "dev", "legacy-user", "org-admin"])
}

@Test func awsProfilesHandlesEmptyInputs() {
    #expect(AWSProfiles.profileNames(configContents: "", credentialsContents: "") == [])
}

@Test func awsProfilesDedupesAcrossFiles() {
    let names = AWSProfiles.profileNames(configContents: "[profile shared]\n", credentialsContents: "[shared]\n")
    #expect(names == ["shared"])
}

@Test func awsProfilesReadsWindowsLineEndings() {
    let names = AWSProfiles.profileNames(configContents: "[profile a]\r\nregion = x\r\n[profile b]\r\n",
                                         credentialsContents: "")
    #expect(names == ["a", "b"])
}

private let kindsConfig = """
[default]
region = us-east-1

[sso-session main]
sso_start_url = https://x.awsapps.com/start

[profile sso-user]
sso_session = main
sso_account_id = 111111111111

[profile admin]
role_arn = arn:aws:iam::111111111111:role/Admin
source_profile = base

[profile mfa]
role_arn = arn:aws:iam::111111111111:role/Admin
mfa_serial = arn:aws:iam::111111111111:mfa/me

[profile proc]
credential_process = /usr/local/bin/get-creds

[profile keys-in-config]
aws_access_key_id = AKIACONFIG
aws_secret_access_key = config-secret
"""

private let kindsCreds = """
[base]
aws_access_key_id = AKIABASE
aws_secret_access_key = base-secret

[temp]
aws_access_key_id = ASIATEMP
aws_secret_access_key = temp-secret
aws_session_token = temp-token

[keys-in-config]
aws_access_key_id = AKIACREDS
aws_secret_access_key = creds-secret

[half]
aws_access_key_id = AKIAHALF
"""

@Test func awsProfilesKinds() {
    func kind(_ n: String) -> AWSProfiles.ProfileKind {
        AWSProfiles.profileKind(n, configContents: kindsConfig, credentialsContents: kindsCreds)
    }
    #expect(kind("sso-user") == .sso)
    #expect(kind("admin") == .assumeRole(sourceProfile: "base"))
    #expect(kind("mfa") == .needsMFA)
    #expect(kind("proc") == .process)
    #expect(kind("base") == .staticKeys)
    #expect(kind("default") == .empty)
    #expect(kind("missing") == .empty)
}

@Test func awsProfilesStaticKeysPreferCredentialsFile() {
    let keys = AWSProfiles.staticKeys("keys-in-config", configContents: kindsConfig, credentialsContents: kindsCreds)
    #expect(keys?.accessKeyId == "AKIACREDS")
    #expect(keys?.secretAccessKey == "creds-secret")
    #expect(keys?.sessionToken == nil)
    let temp = AWSProfiles.staticKeys("temp", configContents: kindsConfig, credentialsContents: kindsCreds)
    #expect(temp?.sessionToken == "temp-token")
}

@Test func awsProfilesStaticKeysNeedBothHalves() {
    #expect(AWSProfiles.staticKeys("half", configContents: kindsConfig, credentialsContents: kindsCreds) == nil)
    #expect(AWSProfiles.staticKeys("sso-user", configContents: kindsConfig, credentialsContents: kindsCreds) == nil)
}

@Test func awsProfilesReadsFromInjectedHome() throws {
    let home = try makeAWSHome(config: kindsConfig, credentials: kindsCreds)
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(AWSProfiles.profileNamesFromDisk(home: home).contains("sso-user"))
    #expect(AWSProfiles.profileKindFromDisk("proc", home: home) == .process)
    #expect(AWSProfiles.staticKeysFromDisk("base", home: home)?.accessKeyId == "AKIABASE")
}

@Test func awsProfilesMissingFilesAreEmpty() {
    let home = FileManager.default.temporaryDirectory.appending(path: "no-such-home-\(UUID().uuidString)")
    #expect(AWSProfiles.profileNamesFromDisk(home: home) == [])
    #expect(AWSProfiles.profileKindFromDisk("default", home: home) == .empty)
}

@Test func awsProfilesNameValidation() {
    for ok in ["default", "org-admin", "my_profile.2", "a@b+c"] {
        #expect(AWSProfiles.isValidName(ok), "\(ok)")
    }
    for bad in ["", "-flag", "has space", "semi;colon", "$(x)", "a/b", "quote'", String(repeating: "a", count: 65)] {
        #expect(!AWSProfiles.isValidName(bad), "\(bad)")
    }
}

/// A throwaway home directory holding `.aws/config` and `.aws/credentials`.
func makeAWSHome(config: String, credentials: String) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "aws-home-\(UUID().uuidString)")
    let aws = home.appending(path: ".aws")
    try FileManager.default.createDirectory(at: aws, withIntermediateDirectories: true)
    try config.write(to: aws.appending(path: "config"), atomically: true, encoding: .utf8)
    try credentials.write(to: aws.appending(path: "credentials"), atomically: true, encoding: .utf8)
    return home
}
