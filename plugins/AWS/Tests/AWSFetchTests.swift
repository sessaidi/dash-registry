import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls AWS (signed for its service and the profile's region) and
/// stores a sanitized answer with a receipt; each reader answers from the store with its
/// freshness, or says what to fetch. No tool Dashii or an agent gets makes a request.
extension AWSPluginTests {
    @MainActor
    @Suite
    struct AWSFetchTests {
        struct Case: Sendable, CustomTestStringConvertible {
            let fetcher: String
            var input: JSONValue = [:]
            let replies: [String: String]
            /// The host and path of a request the fetch must make, and its method.
            let request: String
            var method = "POST"
            let check: @Sendable (JSONValue) -> Bool
            var testDescription: String { fetcher }
        }

        nonisolated static let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        nonisolated static let events = #"{"events":[{"timestamp":1763460000000,"logStreamName":"2026/11/18/[$LATEST]a","message":"start"},"#
            + #"{"timestamp":1763460060000,"logStreamName":"2026/11/18/[$LATEST]a","message":"retry failed with GITHUB_TOKEN=\#(token)\n"}]}"#

        nonisolated static let cases: [Case] = [
            Case(fetcher: "aws.log_groups", input: ["prefix": "/aws/lambda/"],
                 replies: ["Logs_20140328.DescribeLogGroups": #"{"logGroups":[{"logGroupName":"/aws/lambda/billing-api","storedBytes":1024,"retentionInDays":14,"creationTime":1763460000000}]}"#],
                 request: "logs.eu-west-1.amazonaws.com/") {
                $0["items"]?[0]?["name"] == "/aws/lambda/billing-api" && $0["items"]?[0]?["retention_days"] == 14
                    && $0["items"]?[0]?["created"]?.string?.hasPrefix("2025-11-18T") == true
            },
            Case(fetcher: "aws.logs", input: ["group": "/aws/lambda/billing-api", "filter": "ERROR"],
                 replies: ["Logs_20140328.FilterLogEvents": events], request: "logs.eu-west-1.amazonaws.com/") {
                $0["group"] == "/aws/lambda/billing-api" && $0["events"]?.array?.count == 2
                    && $0["events"]?[0]?["message"]?.string?.hasPrefix("retry failed") == true
                    && $0["events"]?[0]?["message"]?.string?.contains("ghp_") == false
            },
            Case(fetcher: "aws.lambda_functions",
                 replies: ["lambda.eu-west-1.amazonaws.com/2015-03-31/functions/": #"{"Functions":[{"FunctionName":"billing-api","Runtime":"python3.12","MemorySize":512,"Timeout":30}]}"#],
                 request: "lambda.eu-west-1.amazonaws.com/2015-03-31/functions/", method: "GET") {
                $0["items"]?[0]?["name"] == "billing-api" && $0["items"]?[0]?["runtime"] == "python3.12" && $0["items"]?[0]?["memory"] == 512
            },
            Case(fetcher: "aws.eks_clusters",
                 replies: ["eks.eu-west-1.amazonaws.com/clusters": #"{"clusters":["prod","../other"]}"#,
                           "eks.eu-west-1.amazonaws.com/clusters/prod": #"{"cluster":{"name":"prod","version":"1.31","status":"ACTIVE","createdAt":1763460000.5}}"#],
                 request: "eks.eu-west-1.amazonaws.com/clusters/prod", method: "GET") {
                $0["items"]?.array?.count == 1 && $0["items"]?[0]?["version"] == "1.31" && $0["items"]?[0]?["status"] == "ACTIVE"
            },
            Case(fetcher: "aws.api", input: ["url": "https://ec2.eu-west-1.amazonaws.com/", "body": "Action=DescribeInstances&Version=2016-11-15"],
                 replies: ["ec2.eu-west-1.amazonaws.com/": "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"],
                 request: "ec2.eu-west-1.amazonaws.com/") {
                $0["text"]?.string?.contains("reservationSet") == true
            },
        ]

        let defaults: UserDefaults

        init() {
            let suite = "AWSFetchTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        }

        /// A started integration on a temporary ~/.aws (keys, eu-west-1), its identity check done;
        /// the table also answers STS.
        func hosted(_ replies: [String: String]) async throws -> (AWSIntegration, TestHost) {
            var table = replies.mapValues { StubURLProtocol.Reply.json($0) }
            table["sts.eu-west-1.amazonaws.com/"] = .json(AWSIntegrationTests.identity)
            StubURLProtocol.reset(table)
            let provider = AWSCredentialsProvider(home: try awsHome(config: "[default]\nregion = eu-west-1\n", credentials: AWSIntegrationTests.keys))
            let aws = AWSIntegration(defaults: defaults, environment: [:], provider: provider, session: StubURLProtocol.session())
            let dash = try TestHost([aws])
            dash.start([aws])
            await aws.loading?.value
            return (aws, dash)
        }

        /// What went to AWS besides the identity check.
        var awsRequests: [URLRequest] { StubURLProtocol.requests.filter { $0.url?.host() != "sts.eu-west-1.amazonaws.com" } }

        @Test(arguments: cases)
        func fetcherStoresAndReaderReads(_ c: Case) async throws {
            let (aws, dash) = try await hosted(c.replies)
            let resource = try #require(aws.resources.first { $0.fetcherName == c.fetcher })

            let before = try #require(try await dash.runTool(resource.readerName, c.input))
            #expect(before["fetched"] == false && before["refresh"]?["fetcher"] == .string(c.fetcher))
            #expect(awsRequests.isEmpty)

            let receipt = try await dash.fetch(c.fetcher, c.input)
            #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0)
            #expect(receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
            #expect(receipt["read_with"]?.string?.hasPrefix(resource.readerName + " {") == true)
            let sent = awsRequests
            #expect(sent.contains { ($0.url?.host() ?? "") + ($0.url?.path() ?? "") == c.request && $0.httpMethod == c.method })
            #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIA1/") == true })

            let answer = try #require(try await dash.runTool(resource.readerName, c.input))
            #expect(c.check(answer), "\(answer.jsonString())")
            #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)

            let again = try await dash.fetch(c.fetcher, c.input)
            #expect(again["stored"] == 0 && again["unchanged"] == 1)
            let stored = dash.testSynced.records(kind: resource.kind, scope: aws.storeScope)
            #expect(stored.count == 1 && stored.allSatisfy { $0.source == "aws" && !$0.value.jsonString().contains("ghp_") })
        }

        @Test func logsAskForTheWindowAndFilter() async throws {
            let (aws, dash) = try await hosted(["Logs_20140328.FilterLogEvents": Self.events])
            let now = Date(timeIntervalSince1970: 1_763_463_600)
            aws.now = { now }
            _ = try await dash.fetch("aws.logs", ["group": "/aws/lambda/billing-api", "filter": "ERROR", "minutes": 30, "limit": 1])
            let body = try JSONValue.parse(try #require(awsRequests.last?.httpBody))
            #expect(body["logGroupName"] == "/aws/lambda/billing-api" && body["filterPattern"] == "ERROR")
            #expect(body["startTime"]?.double == (now.timeIntervalSince1970 - 1800) * 1000)
            let answer = try #require(try await dash.runTool("aws_logs", ["group": "/aws/lambda/billing-api", "filter": "ERROR", "minutes": 30, "limit": 1]))
            // The latest event only.
            #expect(answer["events"]?.array?.count == 1 && answer["events"]?[0]?["timestamp"]?.string?.hasSuffix("T10:01:00Z") == true)
            await #expect(throws: ToolError("Give group.")) { try await dash.runTool("aws_logs", ["group": " "]) }
        }

        @Test func readersSayWhenDataIsStale() async throws {
            let (aws, dash) = try await hosted([
                "Logs_20140328.DescribeLogGroups": #"{"logGroups":[]}"#,
                "eks.eu-west-1.amazonaws.com/clusters": #"{"clusters":[]}"#,
            ])
            _ = try await dash.fetch("aws.log_groups")
            _ = try await dash.fetch("aws.eks_clusters")
            aws.now = { .now.addingTimeInterval(20 * 60) }
            let groups = try #require(try await dash.runTool("aws_log_groups"))
            #expect(groups["stale"] == true && groups["refresh"] == ["fetcher": "aws.log_groups", "input": [:]])
            #expect(try await dash.runTool("aws_eks_clusters")?["stale"] == false)
        }

        @Test func queryAnswersExpireAfterADay() async throws {
            let (aws, dash) = try await hosted(["Logs_20140328.FilterLogEvents": Self.events])
            _ = try await dash.fetch("aws.logs", ["group": "a"])
            aws.now = { .now.addingTimeInterval(2 * 86_400) }
            _ = try await dash.fetch("aws.logs", ["group": "b"])
            #expect(dash.testSynced.records(kind: "aws.logs", scope: aws.storeScope).map { $0.value["input"]?["group"] } == ["b"])
        }

        @Test func recordsArePerProfileAndRegion() async throws {
            let (aws, dash) = try await hosted(["Logs_20140328.DescribeLogGroups": #"{"logGroups":[]}"#])
            #expect(aws.storeScope == "aws:default/eu-west-1")
            _ = try await dash.fetch("aws.log_groups")
            aws.regionOverride = "us-east-2"
            #expect(aws.storeScope == "aws:default/us-east-2")
            #expect(try await dash.runTool("aws_log_groups")?["fetched"] == false)
        }

        @Test func noToolDashiiGetsCallsAWS() async throws {
            let (aws, dash) = try await hosted(["Logs_20140328.FilterLogEvents": Self.events, "Logs_20140328.DescribeLogGroups": #"{"logGroups":[]}"#])
            let values: [String: JSONValue] = ["group": "/aws/lambda/billing-api", "url": "https://ec2.eu-west-1.amazonaws.com/", "method": "GET"]
            #expect(await NetworkSentinel.requests(running: aws.tools, values: values) == [])
            _ = try await dash.fetch("aws.logs", ["group": "/aws/lambda/billing-api"])
            _ = try await dash.fetch("aws.log_groups")
            #expect(await NetworkSentinel.requests(running: aws.tools, values: values) == [])
        }

        @Test func toolsFetchersAndVerbsLineUp() async throws {
            let (aws, _) = try await hosted([:])
            #expect(aws.tools.map(\.name) == ["aws_whoami"] + aws.resources.map(\.readerName))
            #expect(!aws.tools.contains { $0.name == "aws_api" })
            let fetchers = aws.fetchers.map(\.name)
            #expect(fetchers == ["aws.log_groups", "aws.logs", "aws.lambda_functions", "aws.eks_clusters", "aws.api"])
            #expect(aws.verbs.allSatisfy { verb in aws.tools.contains { $0.name == verb.tool } })
            #expect(aws.datasets.map(\.name) == ["aws_logs"])
        }

        @Test func logsDatasetReadsStoredEvents() async throws {
            let (aws, dash) = try await hosted(["Logs_20140328.FilterLogEvents": Self.events])
            let logs = try #require(aws.datasets.first)
            #expect(try await logs.rows(nil).isEmpty)
            _ = try await dash.fetch("aws.logs", ["group": "/aws/lambda/billing-api"])
            _ = try await dash.fetch("aws.logs", ["group": "/aws/lambda/billing-api", "minutes": 120])
            let rows = try await logs.rows(nil)
            // The same events from two overlapping fetches come once, newest first.
            #expect(rows.count == 2 && rows.first?["message"]?.string?.hasPrefix("retry failed") == true)
            #expect(rows.first?["group"] == "/aws/lambda/billing-api" && rows.first?["stale"] == false && rows.first?["synced_at"]?.string != nil)
        }
    }
}
