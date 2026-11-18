import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls Google Cloud and stores a sanitized answer with a receipt;
/// each reader answers from the store with its freshness, or says what to fetch. No tool Dashii or
/// an agent gets makes a request. (In GCPPluginTests: the stub's table is shared, so serialized.)
extension GCPPluginTests {
    struct FetchCase: Sendable, CustomTestStringConvertible {
        let fetcher: String
        let input: JSONValue
        /// Google's answer, by path.
        let routes: [String: JSONValue]
        /// A request the fetch must make.
        let path: String
        var method = "GET"
        let check: @Sendable (JSONValue) -> Bool
        var testDescription: String { fetcher }
    }

    nonisolated static let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    nonisolated static let project: JSONValue = ["project": "acme-dev"]
    nonisolated static let entries: JSONValue = ["entries": [
        ["timestamp": "2026-11-18T10:02:00Z", "severity": "ERROR", "textPayload": .string("retry failed with GITHUB_TOKEN=\(token)"),
         "resource": ["type": "k8s_container", "labels": ["pod_name": "billing-api-1", "container_name": "api"]]],
    ]]

    nonisolated static let fetchCases: [FetchCase] = [
        FetchCase(fetcher: "gcp.projects", input: [:], routes: ["/v1/projects": ["projects": [["projectId": "acme-dev", "name": "Acme Dev", "lifecycleState": "ACTIVE"]]]],
                  path: "/v1/projects") { $0["projects"]?[0]?["projectId"] == "acme-dev" && $0["count"] == 1 },
        FetchCase(fetcher: "gcp.logs", input: ["project": "acme-dev", "namespace": "billing"], routes: ["/v2/entries:list": entries],
                  path: "/v2/entries:list", method: "POST") {
            $0["entries"]?[0]?["pod"] == "billing-api-1" && $0["entries"]?[0]?["message"]?.string?.contains("ghp_") == false
                && $0["filter"]?.string?.contains(#"namespace_name="billing""#) == true
        },
        FetchCase(fetcher: "gcp.metrics", input: ["project": "acme-dev", "metric": "memory"],
                  routes: ["/v3/projects/acme-dev/timeSeries": ["timeSeries": [["resource": ["labels": ["pod_name": "billing-api-1"]],
                                                                                 "points": [["interval": ["endTime": "t"], "value": ["doubleValue": 5]]]]]]],
                  path: "/v3/projects/acme-dev/timeSeries") { $0["series"]?[0]?["pod"] == "billing-api-1" && $0["series"]?[0]?["max"] == 5 },
        FetchCase(fetcher: "gcp.audit_logs", input: project, routes: ["/v2/entries:list": ["entries": []]],
                  path: "/v2/entries:list", method: "POST") { $0["filter"]?.string?.contains("cloudaudit.googleapis.com") == true },
        FetchCase(fetcher: "gcp.gke_clusters", input: project, routes: ["/v1/projects/acme-dev/locations/-/clusters": ["clusters": [["name": "prod"]]]],
                  path: "/v1/projects/acme-dev/locations/-/clusters") { $0["items"]?[0]?["name"] == "prod" },
        FetchCase(fetcher: "gcp.gke_cluster", input: ["project": "acme-dev", "location": "us-east4", "name": "prod"],
                  routes: ["/v1/projects/acme-dev/locations/us-east4/clusters/prod": ["name": "prod", "status": "RUNNING"]],
                  path: "/v1/projects/acme-dev/locations/us-east4/clusters/prod") { $0["status"] == "RUNNING" },
        FetchCase(fetcher: "gcp.cloud_run_services", input: project,
                  routes: ["/v2/projects/acme-dev/locations/-/services": ["services": [["name": "projects/acme-dev/locations/us/services/billing-api"]]]],
                  path: "/v2/projects/acme-dev/locations/-/services") { $0["items"]?[0]?["name"] == "billing-api" },
        FetchCase(fetcher: "gcp.cloud_run_revisions", input: ["project": "acme-dev", "region": "us-east4", "service": "billing-api"],
                  routes: ["/v2/projects/acme-dev/locations/us-east4/services/billing-api/revisions": ["revisions": [["name": "x/revisions/billing-api-001"]]]],
                  path: "/v2/projects/acme-dev/locations/us-east4/services/billing-api/revisions") { $0["items"]?[0]?["name"] == "billing-api-001" },
        FetchCase(fetcher: "gcp.pubsub_topics", input: project, routes: ["/v1/projects/acme-dev/topics": ["topics": [["name": "projects/acme-dev/topics/orders"]]]],
                  path: "/v1/projects/acme-dev/topics") { $0["items"]?[0]?["name"] == "orders" },
        FetchCase(fetcher: "gcp.pubsub_subscriptions", input: project,
                  routes: ["/v1/projects/acme-dev/subscriptions": ["subscriptions": [["name": "projects/acme-dev/subscriptions/orders-billing",
                                                                                      "topic": "projects/acme-dev/topics/orders"]]]],
                  path: "/v1/projects/acme-dev/subscriptions") { $0["items"]?[0]?["topic"] == "orders" },
        FetchCase(fetcher: "gcp.sql_instances", input: project, routes: ["/v1/projects/acme-dev/instances": ["items": [["name": "billing-db", "state": "RUNNABLE"]]]],
                  path: "/v1/projects/acme-dev/instances") { $0["items"]?[0]?["state"] == "RUNNABLE" },
        FetchCase(fetcher: "gcp.artifact_repositories", input: ["project": "acme-dev", "location": "us"],
                  routes: ["/v1/projects/acme-dev/locations/us/repositories": ["repositories": [["name": "x/repositories/images", "format": "DOCKER"]]]],
                  path: "/v1/projects/acme-dev/locations/us/repositories") { $0["items"]?[0]?["name"] == "images" && $0["items"]?[0]?["format"] == "DOCKER" },
        FetchCase(fetcher: "gcp.artifact_images", input: ["project": "acme-dev", "location": "us", "repository": "images"],
                  routes: ["/v1/projects/acme-dev/locations/us/repositories/images/dockerImages": ["dockerImages": [["uri": "us-docker.pkg.dev/acme-dev/images/billing-api", "tags": ["v1"]]]]],
                  path: "/v1/projects/acme-dev/locations/us/repositories/images/dockerImages") { $0["items"]?[0]?["tags"] == ["v1"] },
        FetchCase(fetcher: "gcp.secrets", input: project,
                  routes: ["/v1/projects/acme-dev/secrets": ["secrets": [["name": "projects/acme-dev/secrets/db-password", "replication": ["automatic": [:]]]]]],
                  path: "/v1/projects/acme-dev/secrets") { $0["items"]?[0]?["name"] == "db-password" },
        FetchCase(fetcher: "gcp.iam_policy", input: project,
                  routes: ["/v1/projects/acme-dev:getIamPolicy": ["bindings": [["role": "roles/viewer", "members": ["user:ada@example.com"]]]]],
                  path: "/v1/projects/acme-dev:getIamPolicy", method: "POST") { $0["items"]?[0]?["role"] == "roles/viewer" },
        FetchCase(fetcher: "gcp.compute_instances", input: ["project": "acme-dev", "filter": "status=RUNNING"],
                  routes: ["/compute/v1/projects/acme-dev/aggregated/instances": ["items": ["zones/us-east4-a": ["instances": [["name": "vm-1"]]]]]],
                  path: "/compute/v1/projects/acme-dev/aggregated/instances") { $0["items"]?[0]?["name"] == "vm-1" },
        FetchCase(fetcher: "gcp.cloud_builds", input: project, routes: ["/v1/projects/acme-dev/builds": ["builds": [["id": "b1", "status": "FAILURE"]]]],
                  path: "/v1/projects/acme-dev/builds") { $0["items"]?[0]?["status"] == "FAILURE" },
        FetchCase(fetcher: "gcp.error_groups", input: project,
                  routes: ["/v1beta1/projects/acme-dev/groupStats": ["errorGroupStats": [["group": ["groupId": "g1"], "count": "42"]]]],
                  path: "/v1beta1/projects/acme-dev/groupStats") { $0["items"]?[0]?["group"] == "g1" },
        FetchCase(fetcher: "gcp.uptime_checks", input: project,
                  routes: ["/v3/projects/acme-dev/uptimeCheckConfigs": ["uptimeCheckConfigs": [["displayName": "billing-api health"]]]],
                  path: "/v3/projects/acme-dev/uptimeCheckConfigs") { $0["items"]?[0]?["name"] == "billing-api health" },
        FetchCase(fetcher: "gcp.api", input: ["url": "https://container.googleapis.com/v1/projects/acme-dev/locations/-/clusters"],
                  routes: ["/v1/projects/acme-dev/locations/-/clusters": ["clusters": [["name": "prod"]]]],
                  path: "/v1/projects/acme-dev/locations/-/clusters") { $0["clusters"]?[0]?["name"] == "prod" },
    ]

    /// Answers by path; the OAuth endpoints get a token.
    func table(_ routes: [String: JSONValue]) -> StubProtocol.Handler {
        { request, _ in
            if request.url?.host() == "oauth2.googleapis.com" { return (200, tokenResponse) }
            return routes[request.url?.path() ?? ""].map { (200, json($0)) } ?? (404, json(["error": ["message": "not found"]]))
        }
    }

    // MARK: Fetchers and readers

    @MainActor
    @Test(arguments: fetchCases)
    func fetcherStoresAndReaderReads(_ c: FetchCase) async throws {
        let (gcp, file, dash) = try hosted(table(c.routes))
        defer { try? FileManager.default.removeItem(at: file) }
        let resource = try #require(gcp.resources.first { $0.fetcherName == c.fetcher })

        let before = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(before["fetched"] == false && before["rows"] == [])
        #expect(before["refresh"]?["fetcher"] == .string(c.fetcher))
        #expect(googleRequests.isEmpty)

        let receipt = try await dash.fetch(c.fetcher, c.input)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0)
        #expect(receipt["keys"]?.array?.count == 1 && receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
        #expect(receipt["synced_at"]?.string != nil)
        #expect(receipt["read_with"]?.string?.hasPrefix(resource.readerName + " {") == true)
        let sent = googleRequests.map(\.request)
        #expect(sent.contains { $0.url?.path() == c.path && $0.httpMethod == c.method })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.test" })

        let answer = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(c.check(answer), "\(answer.jsonString())")
        #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)
        #expect(answer["refresh"]?["fetcher"] == .string(c.fetcher))

        let again = try await dash.fetch(c.fetcher, c.input)
        #expect(again["stored"] == 0 && again["unchanged"] == 1)
        let stored = dash.testSynced.records(kind: resource.kind, scope: gcp.storeScope)
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { !$0.value.jsonString().contains("ghp_") && !$0.value.jsonString().contains("ya29.") && $0.source == "gcp" })
    }

    @MainActor
    @Test func readersSayWhenDataIsStale() async throws {
        let (gcp, file, dash) = try hosted(table(["/v2/entries:list": Self.entries, "/v1/projects/acme-dev/topics": ["topics": []]]))
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await dash.fetch("gcp.logs", Self.project)
        _ = try await dash.fetch("gcp.pubsub_topics", Self.project)
        gcp.now = { .now.addingTimeInterval(10 * 60) }
        let logs = try #require(try await dash.runTool("gcp_logs_query", Self.project))
        #expect(logs["stale"] == true && logs["entries"]?.array?.count == 1)
        #expect(logs["refresh"] == ["fetcher": "gcp.logs", "input": Self.project])
        // Topics stay fresh for an hour.
        #expect(try await dash.runTool("gcp_pubsub_topics", Self.project)?["stale"] == false)
    }

    @MainActor
    @Test func inputsAreNormalizedAndPathSegmentsChecked() async throws {
        let (_, file, dash) = try hosted(table(["/v1/projects/acme-dev/topics": ["topics": [["name": "projects/acme-dev/topics/orders"]]]]))
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await dash.fetch("gcp.pubsub_topics", Self.project)
        let answer = try #require(try await dash.runTool("gcp_pubsub_topics", ["project": "  acme-dev ", "extra": 1]))
        #expect(answer.object?.keys.contains("fetched") == false && answer["items"]?.array?.count == 1)
        await #expect(throws: ToolError("Give project.")) { _ = try await dash.runTool("gcp_pubsub_topics", [:]) }
        await #expect(throws: ToolError("Give project and metric.")) { _ = try await dash.runTool("gcp_metrics_query", ["project": " "]) }
        let before = googleRequests.count
        for (fetcher, input) in [("gcp.pubsub_topics", ["project": "acme-dev/../other"]), ("gcp.gke_cluster", ["project": "acme-dev", "location": "us", "name": "../x"]),
                                 ("gcp.cloud_run_revisions", ["project": "acme-dev", "region": "us", "service": "a/b"]),
                                 ("gcp.artifact_images", ["project": "acme-dev", "location": "us", "repository": "images", "package": "../x"])] as [(String, JSONValue)] {
            await #expect(throws: ToolError.self, "\(fetcher)") { _ = try await dash.fetch(fetcher, input) }
        }
        #expect(googleRequests.count == before)
        // Domain-scoped project ids keep their colon and dots.
        #expect(throws: Never.self) { try GCPIntegration.checkSegment("project", "example.com:acme-dev") }
    }

    @MainActor
    @Test func queryAnswersExpireAfterADay() async throws {
        let (gcp, file, dash) = try hosted(table(["/v2/entries:list": Self.entries]))
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await dash.fetch("gcp.logs", Self.project)
        gcp.now = { .now.addingTimeInterval(2 * 86_400) }
        _ = try await dash.fetch("gcp.logs", ["project": "acme-dev", "minSeverity": "ERROR"])
        let stored = dash.testSynced.records(kind: "gcp.logs", scope: gcp.storeScope)
        #expect(stored.map { $0.value["input"]?["minSeverity"] } == ["ERROR"])
    }

    @MainActor
    @Test func bigAnswersAreCappedAndSecretValuesRefused() async throws {
        let (gcp, file, dash) = try hosted(table(["/storage/v1/b": ["blob": .string(String(repeating: "a", count: 300_000))]]))
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await dash.fetch("gcp.api", ["url": "https://storage.googleapis.com/storage/v1/b"])
        let stored = try #require(dash.testSynced.records(kind: "gcp.api", scope: gcp.storeScope).first)
        #expect(stored.value.jsonString().utf8.count < 201_000)
        await #expect(throws: ToolError("Secret values can't be read; gcp_secrets lists names and metadata.")) {
            _ = try await dash.fetch("gcp.api", ["url": "https://secretmanager.googleapis.com/v1/projects/acme-dev/secrets/db-password/versions/latest:access"])
        }
        #expect(!googleRequests.contains { $0.request.url?.path().contains(":access") == true })
    }

    @MainActor
    @Test func recordsArePerCredentials() throws {
        let (gcp, file) = try integration(table([:]))
        defer { try? FileManager.default.removeItem(at: file) }
        let other = GCPIntegration(credentialsPath: file.path + ".other", session: StubProtocol.session(table([:])))
        #expect(gcp.storeScope.hasPrefix("gcp:") && gcp.storeScope.count == "gcp:".count + 12)
        #expect(gcp.storeScope != other.storeScope && !gcp.storeScope.contains("/"))
    }

    // MARK: No network for Dashii and agents

    @MainActor
    @Test func noToolDashiiGetsCallsGoogle() async throws {
        let (gcp, file, dash) = try hosted(table(["/v2/entries:list": Self.entries, "/v1/projects/acme-dev/topics": ["topics": []]]))
        defer { try? FileManager.default.removeItem(at: file) }
        let values: [String: JSONValue] = ["project": "acme-dev", "url": "https://container.googleapis.com/v1/projects/acme-dev/locations/-/clusters",
                                           "location": "us", "name": "prod", "region": "us", "service": "billing-api", "repository": "images"]
        #expect(await NetworkSentinel.requests(running: gcp.tools, values: values) == [])
        _ = try await dash.fetch("gcp.logs", Self.project)
        _ = try await dash.fetch("gcp.pubsub_topics", Self.project)
        #expect(await NetworkSentinel.requests(running: gcp.tools, values: values) == [])
    }

    @MainActor
    @Test func toolsFetchersAndVerbsLineUp() throws {
        let (gcp, file) = try integration(table([:]))
        defer { try? FileManager.default.removeItem(at: file) }
        let tools = gcp.tools
        #expect(tools.map(\.name) == gcp.resources.map(\.readerName))
        #expect(!tools.contains { $0.name == "gcp_api_get" })
        let fetchers = gcp.fetchers.map(\.name)
        #expect(fetchers.count == gcp.resources.count && fetchers.allSatisfy { $0.hasPrefix("gcp.") } && Set(fetchers).count == fetchers.count)
        #expect(gcp.verbs.allSatisfy { verb in tools.contains { $0.name == verb.tool } })
        #expect(gcp.datasets.map(\.name) == ["gcp_logs", "gcp_errors", "gcp_builds"])
    }

    @MainActor
    @Test func datasetsReadStoredAnswers() async throws {
        let (gcp, file, dash) = try hosted(table([
            "/v2/entries:list": Self.entries,
            "/v1beta1/projects/acme-dev/groupStats": ["errorGroupStats": [["group": ["groupId": "g1"], "count": "42", "representative": ["message": "boom"]]]],
            "/v1/projects/acme-dev/builds": ["builds": [["id": "b1", "status": "FAILURE", "startTime": "2026-11-18T09:00:00Z"]]],
        ]))
        defer { try? FileManager.default.removeItem(at: file) }
        let logs = try #require(gcp.datasets.first { $0.name == "gcp_logs" })
        #expect(try await logs.rows(nil).isEmpty)
        _ = try await dash.fetch("gcp.logs", Self.project)
        _ = try await dash.fetch("gcp.logs", ["project": "acme-dev", "since": "6h"])
        _ = try await dash.fetch("gcp.error_groups", Self.project)
        _ = try await dash.fetch("gcp.cloud_builds", Self.project)
        let rows = try await logs.rows(nil)
        // The same entry from two overlapping fetches comes once.
        #expect(rows.count == 1 && rows.first?["pod"] == "billing-api-1" && rows.first?["project"] == "acme-dev")
        #expect(rows.first?["stale"] == false && rows.first?["synced_at"]?.string != nil)
        let errors = try await #require(gcp.datasets.first { $0.name == "gcp_errors" }).rows(nil)
        #expect(errors.first?["group"] == "g1" && errors.first?["count"] == 42)
        let builds = try await #require(gcp.datasets.first { $0.name == "gcp_builds" }).rows(nil)
        #expect(builds.first?["id"] == "b1" && builds.first?["status"] == "FAILURE")
    }

    @MainActor
    @Test func pubsubBecomesKnowledgeLinkedToTheCode() async throws {
        let (gcp, file, dash) = try hosted(table([
            "/v1/projects/acme-dev/topics": ["topics": [["name": "projects/acme-dev/topics/orders"]]],
            "/v1/projects/acme-dev/subscriptions": ["subscriptions": [["name": "projects/acme-dev/subscriptions/orders-billing", "topic": "projects/acme-dev/topics/orders",
                                                                      "pushConfig": ["pushEndpoint": "https://billing-api.example.com/push"]]]],
        ]))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(gcp.knowledge.isEmpty)
        _ = try await dash.fetch("gcp.pubsub_topics", Self.project)
        _ = try await dash.fetch("gcp.pubsub_subscriptions", Self.project)
        let entities = gcp.knowledge
        #expect(knowledgeIssues(entities) == [])
        #expect(entities.map(\.id) == ["topic:gcp:acme-dev/subscriptions/orders-billing", "topic:gcp:acme-dev/topics/orders"])
        let topic = try #require(entities.last)
        #expect(topic.kind == "topic" && topic.links == [KnowledgeLink(to: "topic:pubsub:orders", kind: "same_as")])
        let subscription = try #require(entities.first)
        #expect(subscription.links.contains(KnowledgeLink(to: "topic:gcp:acme-dev/topics/orders", kind: "subscribes_to")))
        #expect(subscription.text.contains("pushes to https://billing-api.example.com/push"))
    }
}
