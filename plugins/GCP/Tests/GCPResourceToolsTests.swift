import DashKit
import Foundation
import Testing

/// The resource tools: what they ask Google for, what they keep, and that they only read.
extension GCPPluginTests {
    @MainActor
    private func run(_ gcp: GCPIntegration, _ name: String, _ input: JSONValue) async throws -> JSONValue {
        try await #require(gcp.tools.first { $0.name == name }).run(input)
    }

    /// Answers Google API calls by path; OAuth token requests get a token.
    private func routes(_ table: [String: JSONValue]) -> StubProtocol.Handler {
        { request, _ in
            if request.url?.host() == "oauth2.googleapis.com" { return (200, tokenResponse) }
            return table[request.url?.path() ?? ""].map { (200, json($0)) } ?? (404, json(["error": ["message": "not found"]]))
        }
    }

    @MainActor
    @Test func gkeClustersAreTrimmed() async throws {
        let (gcp, file) = try integration(routes(["/v1/projects/p/locations/-/clusters": ["clusters": [[
            "name": "prod", "location": "us-east4", "status": "RUNNING", "currentMasterVersion": "1.31", "currentNodeCount": 12,
            "masterAuth": ["clusterCaCertificate": "secret-ish"],
            "nodePools": [["name": "default", "version": "1.31", "config": ["machineType": "e2-standard-8"], "autoscaling": ["enabled": true]]],
        ]]]]))
        defer { try? FileManager.default.removeItem(at: file) }
        let clusters = try await run(gcp, "gcp_gke_clusters", ["project": "p"])
        let cluster = try #require(clusters.array?.first)
        #expect(cluster["name"] == "prod" && cluster["nodes"] == 12 && cluster["node_pools"]?[0]?["machine"] == "e2-standard-8")
        #expect(cluster["masterAuth"] == nil)
        #expect(StubProtocol.requests.filter { $0.request.url?.host() == "container.googleapis.com" }.allSatisfy { $0.request.httpMethod == "GET" })
    }

    @MainActor
    @Test func cloudRunFollowsPages() async throws {
        let (gcp, file) = try integration { request, _ in
            if request.url?.host() == "oauth2.googleapis.com" { return (200, tokenResponse) }
            let second = request.url?.query()?.contains("pageToken=next") == true
            let service: JSONValue = ["name": .string("projects/p/locations/us/services/\(second ? "b" : "a")"), "uri": "https://x.run.app",
                                      "latestReadyRevision": "projects/p/locations/us/services/a/revisions/a-001",
                                      "template": ["containers": [["image": "us-docker.pkg.dev/p/r/a:1"]]], "terminalCondition": ["state": "CONDITION_SUCCEEDED"]]
            return (200, json(second ? ["services": [service]] : ["services": [service], "nextPageToken": "next"]))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let services = try await run(gcp, "gcp_cloud_run_services", ["project": "p"])
        #expect(services.array?.map { $0["name"] } == ["a", "b"])
        #expect(services.array?.first?["revision"] == "a-001" && services.array?.first?["image"] == "us-docker.pkg.dev/p/r/a:1")
    }

    @MainActor
    @Test func pubsubBacklogComesFromMonitoring() async throws {
        let (gcp, file) = try integration { request, _ in
            switch (request.url?.host(), request.url?.path()) {
            case ("oauth2.googleapis.com", _): return (200, tokenResponse)
            case (_, "/v1/projects/p/subscriptions"):
                return (200, json(["subscriptions": [["name": "projects/p/subscriptions/orders", "topic": "projects/p/topics/orders", "ackDeadlineSeconds": 10]]]))
            case (_, "/v3/projects/p/timeSeries"):
                let age = request.url?.query()?.contains("oldest_unacked") == true
                return (200, json(["timeSeries": [["resource": ["labels": ["subscription_id": "orders"]], "points": [["value": ["int64Value": age ? "90" : "1234"]]]]]]))
            default: return (404, Data())
            }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let subscription = try #require(try await run(gcp, "gcp_pubsub_subscriptions", ["project": "p", "backlog": true]).array?.first)
        #expect(subscription["name"] == "orders" && subscription["topic"] == "orders")
        #expect(subscription["undelivered"] == 1234 && subscription["oldest_unacked_seconds"] == 90)
    }

    @MainActor
    @Test func secretsAreNamesOnlyAndValuesAreRefused() async throws {
        let (gcp, file) = try integration(routes(["/v1/projects/p/secrets": ["secrets": [[
            "name": "projects/p/secrets/db-password", "createTime": "2026-01-01T00:00:00Z", "replication": ["automatic": [:]],
        ]]]]))
        defer { try? FileManager.default.removeItem(at: file) }
        let secret = try #require(try await run(gcp, "gcp_secrets", ["project": "p"]).array?.first)
        #expect(secret["name"] == "db-password" && secret["replication"] == "automatic")
        #expect(StubProtocol.requests.allSatisfy { !($0.request.url?.path().contains(":access") ?? false) })
        await #expect(throws: ToolError.self) {
            try await run(gcp, "gcp_api_get", ["url": "https://secretmanager.googleapis.com/v1/projects/p/secrets/db-password/versions/latest:access"])
        }
    }

    @MainActor
    @Test func iamPolicyIsTheOneReadOnlyPost() async throws {
        let (gcp, file) = try integration(routes(["/v1/projects/p:getIamPolicy": ["bindings": [["role": "roles/viewer", "members": ["user:ada@example.com"]]]]]))
        defer { try? FileManager.default.removeItem(at: file) }
        let bindings = try await run(gcp, "gcp_iam_policy", ["project": "p"])
        #expect(bindings.array?.first?["role"] == "roles/viewer")
        let call = try #require(StubProtocol.requests.last { $0.request.url?.host() == "cloudresourcemanager.googleapis.com" })
        #expect(call.request.httpMethod == "POST" && call.request.url?.path() == "/v1/projects/p:getIamPolicy")
        await #expect(throws: ToolError.self) { try await run(gcp, "gcp_iam_policy", ["project": "p/../q"]) }
    }

    @MainActor
    @Test func computeAggregatesZones() async throws {
        let (gcp, file) = try integration(routes(["/compute/v1/projects/p/aggregated/instances": ["items": [
            "zones/us-east4-a": ["instances": [["name": "vm-1", "zone": "projects/p/zones/us-east4-a", "status": "RUNNING",
                                                "machineType": "projects/p/zones/us-east4-a/machineTypes/e2-small",
                                                "networkInterfaces": [["networkIP": "10.0.0.2"]]]]],
            "zones/us-east4-b": ["warning": ["code": "NO_RESULTS_ON_PAGE"]],
        ]]]))
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try #require(try await run(gcp, "gcp_compute_instances", ["project": "p"]).array?.first)
        #expect(vm["zone"] == "us-east4-a" && vm["machine"] == "e2-small" && vm["internal_ip"] == "10.0.0.2")
    }

    @MainActor
    @Test func errorGroupsAndBuildsAreTrimmed() async throws {
        let (gcp, file) = try integration(routes([
            "/v1beta1/projects/p/groupStats": ["errorGroupStats": [["group": ["groupId": "g1"], "count": "42",
                "representative": ["message": .string(String(repeating: "e", count: 2_000)), "serviceContext": ["service": "api", "version": "1.2"]]]]],
            "/v1/projects/p/builds": ["builds": [["id": "b1", "status": "FAILURE", "substitutions": ["REPO_NAME": "api", "BRANCH_NAME": "main", "SHORT_SHA": "abc123"],
                                                  "failureInfo": ["detail": "step 2 failed"], "steps": [["name": "huge"]]]]],
        ]))
        defer { try? FileManager.default.removeItem(at: file) }
        let group = try #require(try await run(gcp, "gcp_error_groups", ["project": "p"]).array?.first)
        #expect(group["service"] == "api" && group["count"] == "42" && group["message"]?.string?.count == 1_501)
        let build = try #require(try await run(gcp, "gcp_cloud_builds", ["project": "p", "filter": #"status="FAILURE""#]).array?.first)
        #expect(build["branch"] == "main" && build["failure"] == "step 2 failed" && build["steps"] == nil)
        let sent = try #require(StubProtocol.requests.last { $0.request.url?.host() == "cloudbuild.googleapis.com" }?.request.url)
        #expect(URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter" }?.value == #"status="FAILURE""#)
    }

    @Test func auditFilterTargetsAdminActivity() {
        let filter = GCPIntegration.auditFilter(project: "p", principal: "ada@example.com", method: "SetIamPolicy")
        #expect(filter == #"logName="projects/p/logs/cloudaudit.googleapis.com%2Factivity" AND protoPayload.authenticationInfo.principalEmail="ada@example.com" AND protoPayload.methodName:"SetIamPolicy""#)
    }
}
