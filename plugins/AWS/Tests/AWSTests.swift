import DashKit
import DashKitTesting
import DashKitUI
import CryptoKit
import Foundation
import Testing

/// A temporary home with ~/.aws/config, ~/.aws/credentials and optionally one SSO cache entry.
func awsHome(config: String, credentials: String = "", ssoCache: (String, String)? = nil) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "aws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home.appending(path: ".aws/sso/cache"), withIntermediateDirectories: true)
    try config.write(to: home.appending(path: ".aws/config"), atomically: true, encoding: .utf8)
    try credentials.write(to: home.appending(path: ".aws/credentials"), atomically: true, encoding: .utf8)
    if let (key, json) = ssoCache {
        let name = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        try json.write(to: home.appending(path: ".aws/sso/cache/\(name).json"), atomically: true, encoding: .utf8)
    }
    return home
}

/// One serialized tree: both suites share StubURLProtocol's table.
@Suite(.serialized)
enum AWSPluginTests {}

extension AWSPluginTests {
    @Suite
    struct AWSAuthTests {
        /// AWS's published Signature Version 4 example (IAM ListUsers, 2015-08-30).
        @Test func signatureMatchesTheAWSExample() {
            var request = URLRequest(url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
            let signed = SigV4.sign(request, credentials: .init(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                                    service: "iam", region: "us-east-1", date: date)
            #expect(signed.value(forHTTPHeaderField: "Authorization") ==
                "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
            #expect(signed.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        }

        @Test func scopeComesFromTheHost() {
            #expect(SigV4.scope(for: "ec2.eu-west-1.amazonaws.com", defaultRegion: "us-east-1") == ("ec2", "eu-west-1"))
            #expect(SigV4.scope(for: "iam.amazonaws.com", defaultRegion: "eu-west-1") == ("iam", "us-east-1"))
            #expect(SigV4.scope(for: "logs.amazonaws.com", defaultRegion: "eu-west-3") == ("logs", "eu-west-3"))
        }

        @Test func mergesConfigAndCredentialsProfiles() async throws {
            let home = try awsHome(config: "[default]\nregion = eu-west-1\n[profile ci]\nregion=us-east-2\n", credentials: "[default]\naws_access_key_id = AKIA1\naws_secret_access_key = s\n")
            let provider = AWSCredentialsProvider(home: home)
            let profiles = await provider.profiles()
            #expect(profiles.map(\.name) == ["ci", "default"])
            #expect(profiles.last?.region == "eu-west-1")
            #expect(try await provider.credentials(profile: "default") == AWSCredentials(accessKeyID: "AKIA1", secretAccessKey: "s"))
            await #expect(throws: ToolError.self) { _ = try await provider.credentials(profile: "ci") }
        }

        @Test func ssoProfileUsesCachedTokenForRoleCredentials() async throws {
            let config = """
                [profile dev]
                sso_session = corp
                sso_account_id = 123456789012
                sso_role_name = Developer
                region = eu-west-1

                [sso-session corp]
                sso_region = us-east-1
                sso_start_url = https://corp.awsapps.com/start
                """
            let home = try awsHome(config: config, ssoCache: ("corp", #"{"accessToken":"sso-token","expiresAt":"2099-01-01T00:00:00Z"}"#))
            StubURLProtocol.reset(["/federation/credentials": .json(#"{"roleCredentials":{"accessKeyId":"ASIA9","secretAccessKey":"sec","sessionToken":"tok","expiration":4102444800000}}"#)])
            let provider = AWSCredentialsProvider(home: home, session: StubURLProtocol.session())
            let credentials = try await provider.credentials(profile: "dev")
            #expect(credentials.accessKeyID == "ASIA9" && credentials.sessionToken == "tok")
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.url?.host() == "portal.sso.us-east-1.amazonaws.com")
            #expect(request.url?.query()?.contains("account_id=123456789012") == true)
            #expect(request.value(forHTTPHeaderField: "x-amz-sso_bearer_token") == "sso-token")
        }

        @Test func refusesCredentialProcessProfiles() async throws {
            let home = try awsHome(config: "[profile p]\ncredential_process = /usr/local/bin/get-creds\n")
            await #expect(throws: ToolError.self) { _ = try await AWSCredentialsProvider(home: home).credentials(profile: "p") }
        }
    }
}

extension AWSPluginTests {
    @MainActor
    @Suite
    struct AWSIntegrationTests {
        let defaults: UserDefaults

        init() {
            let suite = "AWSPluginTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }

        static let keys = "[default]\naws_access_key_id = AKIA1\naws_secret_access_key = s\n"
        static let identity = "<GetCallerIdentityResponse><GetCallerIdentityResult><Arn>arn:aws:iam::123456789012:user/jdoe</Arn></GetCallerIdentityResult></GetCallerIdentityResponse>"

        /// An integration on a temporary ~/.aws, loaded (one STS call when the profile resolves).
        func make(config: String = "[default]\nregion = eu-west-1\n", credentials: String = keys, environment: [String: String] = [:]) async throws -> AWSIntegration {
            let provider = AWSCredentialsProvider(home: try awsHome(config: config, credentials: credentials))
            let aws = AWSIntegration(defaults: defaults, environment: environment, provider: provider, session: StubURLProtocol.session())
            await aws.reload()
            return aws
        }

        func tool(_ aws: AWSIntegration, _ name: String) throws -> DashiiTool {
            try #require(aws.tools.first { $0.name == name })
        }

        /// `make()` in a started test host, its identity check done.
        func hosted(config: String = "[default]\nregion = eu-west-1\n") async throws -> (AWSIntegration, TestHost) {
            let aws = try await make(config: config)
            let dash = try TestHost([aws])
            dash.start([aws])
            await aws.loading?.value
            return (aws, dash)
        }

        // MARK: Identity

        @Test func identityAndMetadata() {
            let aws = AWSIntegration(defaults: defaults, environment: [:])
            #expect(aws.id == "aws")
            #expect(aws.name == "AWS")
            #expect(aws.layer == .integration)
            #expect(aws.metadata.version == "1.1.0")
            #expect(aws.metadata.category == .cloud)
            #expect(aws.secretKeys.isEmpty && aws.secrets?.extensionID == nil)
            #expect(aws.tools.map(\.name) == ["aws_whoami", "aws_log_groups", "aws_logs", "aws_lambda_functions", "aws_eks_clusters", "aws_api_read"])
            #expect(aws.tools.allSatisfy { !$0.requiresApproval && $0.isForDashii && !$0.callsService })
        }

        @Test func pluginEntryPoint() {
            let extensions = AWSPlugin.makeExtensions()
            #expect(extensions.map(\.id) == ["aws"])
        }

        // MARK: Storage

        @Test func profileComesFromDefaultsThenEnvironment() {
            #expect(AWSIntegration(defaults: defaults, environment: [:]).profileName == "default")
            #expect(AWSIntegration(defaults: defaults, environment: ["AWS_PROFILE": "prod"]).profileName == "prod")
            defaults.set("dev", forKey: "aws.profile")
            defaults.set("eu-central-1", forKey: "aws.region")
            let aws = AWSIntegration(defaults: defaults, environment: ["AWS_PROFILE": "prod"])
            #expect(aws.profileName == "dev")
            #expect(aws.regionOverride == "eu-central-1")
            aws.regionOverride = ""
            #expect(defaults.string(forKey: "aws.region") == "")
        }

        // MARK: Connection

        @Test func reloadLearnsTheCallerIdentity() async throws {
            StubURLProtocol.reset(["/": .json(Self.identity)])
            let aws = try await make()
            #expect(aws.profiles.map(\.name) == ["default"])
            #expect(aws.region == "eu-west-1")
            #expect(aws.identity == "arn:aws:iam::123456789012:user/jdoe")
            #expect(aws.connectionState == .connected("arn:aws:iam::123456789012:user/jdoe"))
            #expect(aws.isConnected)
            let sent = try #require(StubURLProtocol.requests.last)
            #expect(sent.url?.absoluteString == "https://sts.eu-west-1.amazonaws.com/")
            #expect(sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIA1/") == true)
            #expect(sent.value(forHTTPHeaderField: "Authorization")?.contains("/eu-west-1/sts/aws4_request") == true)
        }

        @Test func regionOverrideWins() async throws {
            StubURLProtocol.reset(["/": .json(Self.identity)])
            let aws = try await make()
            aws.regionOverride = "ap-south-1"
            #expect(aws.region == "ap-south-1")
            #expect(aws.connection?.baseURL.absoluteString == "https://sts.ap-south-1.amazonaws.com")
        }

        @Test func missingProfiles() async throws {
            StubURLProtocol.reset([:])
            let empty = try await make(config: "", credentials: "")
            #expect(empty.connectionState == .failed("No profiles in ~/.aws/config or ~/.aws/credentials."))
            #expect(empty.connection == nil)
            let other = try await make(environment: ["AWS_PROFILE": "nope"])
            #expect(other.connectionState == .failed("Choose a profile."))
            #expect(!other.isConnected)
            try await other.prepare(host: FakeHost([]))
            #expect(StubURLProtocol.requests.isEmpty)
        }

        @Test func rejectedIdentityFailsPrepare() async throws {
            StubURLProtocol.reset(["/": .json("<ErrorResponse/>", status: 403)])
            let aws = try await make()
            #expect(aws.identity == nil)
            guard case .failed = aws.connectionState else { Issue.record("expected failure"); return }
            await #expect(throws: ToolError.self) { try await aws.prepare(host: FakeHost([])) }
        }

        @Test func allowsOnlyAmazonHosts() async throws {
            StubURLProtocol.reset(["/": .json(Self.identity)])
            let connection = try #require(try await make().connection)
            #expect(connection.allows(URL(string: "https://ec2.eu-west-1.amazonaws.com/")!))
            #expect(!connection.allows(URL(string: "https://amazonaws.com.evil.test/")!))
            #expect(!connection.allows(URL(string: "http://ec2.eu-west-1.amazonaws.com/")!))
        }

        // MARK: Fetch, then read

        @Test func apiSignsForTheHostServiceAndRegion() async throws {
            StubURLProtocol.reset(["/": .json(#"{"logGroups":[]}"#)])
            let (_, dash) = try await hosted()
            let input: JSONValue = [
                "url": "https://logs.us-west-2.amazonaws.com/", "body": "{}",
                "content_type": "application/x-amz-json-1.1", "target": "Logs_20140328.DescribeLogGroups",
            ]
            _ = try await dash.fetch("aws.api", input)
            #expect(try await dash.runTool("aws_api_read", input)?["logGroups"] == [])
            let sent = try #require(StubURLProtocol.requests.last)
            #expect(sent.httpMethod == "POST")
            #expect(sent.value(forHTTPHeaderField: "X-Amz-Target") == "Logs_20140328.DescribeLogGroups")
            #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.1")
            #expect(sent.value(forHTTPHeaderField: "Authorization")?.contains("/us-west-2/logs/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-target,") == true)
        }

        @Test func apiRefusesOtherHosts() async throws {
            StubURLProtocol.reset(["/": .json(Self.identity)])
            let (_, dash) = try await hosted()
            let before = StubURLProtocol.requests.count
            await #expect(throws: ToolError("Only https://*.amazonaws.com URLs can be signed.")) {
                try await dash.fetch("aws.api", ["url": "https://example.com/", "method": "GET"])
            }
            await #expect(throws: ToolError("Only https://*.amazonaws.com URLs can be signed.")) {
                try await dash.runTool("aws_api_read", ["url": "https://amazonaws.com.evil.test/", "method": "GET"])
            }
            #expect(StubURLProtocol.requests.count == before)
        }

        @Test func apiRefusesActionsThatChangeAWS() async throws {
            StubURLProtocol.reset(["/": .json(Self.identity)])
            let (aws, dash) = try await hosted()
            let before = StubURLProtocol.requests.count
            await #expect(throws: ToolError.self) {
                try await dash.fetch("aws.api", ["url": "https://ec2.eu-west-1.amazonaws.com/", "body": "Action=TerminateInstances&InstanceId.1=i-1"])
            }
            await #expect(throws: ToolError.self) {
                try await dash.fetch("aws.api", ["url": "https://logs.us-west-2.amazonaws.com/", "body": "{}", "target": "Logs_20140328.DeleteLogGroup"])
            }
            #expect(StubURLProtocol.requests.count == before)
            #expect(aws.tools.allSatisfy { !$0.requiresApproval })
            #expect(throws: Never.self) {
                try AWSIntegration.requireReadOnly(method: "POST", url: URL(string: "https://ec2.amazonaws.com/?Action=DescribeInstances")!, body: nil, target: nil)
            }
        }

        @Test func apiTruncatesLargeResponses() async throws {
            StubURLProtocol.reset(["/": .json(String(repeating: "x", count: 120_000))])
            let (_, dash) = try await hosted()
            let input: JSONValue = ["url": "https://ec2.eu-west-1.amazonaws.com/", "method": "GET"]
            _ = try await dash.fetch("aws.api", input)
            let text = try #require(try await dash.runTool("aws_api_read", input)?["text"]?.string)
            #expect(text.hasSuffix("\n[truncated]"))
            #expect(text.count == AWSIntegration.maxToolCharacters + "\n[truncated]".count)
        }

        @Test func whoamiReadsTheCheckedIdentity() async throws {
            StubURLProtocol.reset(["/": .json(Self.identity)])
            let aws = try await make()
            let before = StubURLProtocol.requests.count
            let answer = try await tool(aws, "aws_whoami").run([:])
            #expect(answer["arn"] == "arn:aws:iam::123456789012:user/jdoe" && answer["profile"] == "default" && answer["region"] == "eu-west-1")
            #expect(answer["checked_at"]?.string != nil && answer["error"] == nil)
            #expect(StubURLProtocol.requests.count == before)

            StubURLProtocol.reset(["/": .json("<ErrorResponse/>", status: 403)])
            await aws.reload()
            let failed = try await tool(aws, "aws_whoami").run([:])
            #expect(failed["arn"] == .null && failed["error"]?.string != nil && failed["hint"]?.string != nil)
        }

        // MARK: Settings

        @Test func featuresUsingListsDependents() {
            let aws = AWSIntegration(defaults: defaults, environment: [:], provider: AWSCredentialsProvider(home: URL(filePath: "/nonexistent")))
            let host = FakeHost([aws, FakeFeature("ec2", requires: ["aws"]), FakeFeature("eks", optional: ["aws", "gcp"]), FakeFeature("gke", requires: ["gcp"])])
            aws.start(host: host)
            #expect(aws.host === host)
            #expect(FeaturesUsingSection.features(using: "aws", in: host.extensions).map(\.id) == ["ec2", "eks"])
            _ = aws.settingsView()
        }
    }
}
