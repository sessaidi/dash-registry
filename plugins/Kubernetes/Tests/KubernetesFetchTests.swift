import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls the cluster and stores a sanitized answer with a receipt;
/// each reader answers from the store with its freshness, or says what to fetch. No tool Dashii or
/// an agent gets makes a request. Every test has its own stub cluster.
@MainActor
struct KubernetesFetchTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fetcher: String
        let input: JSONValue
        let routes: [String: String]
        /// A request the fetch must make.
        let path: String
        let check: @Sendable (JSONValue) -> Bool
        var testDescription: String { fetcher }
    }

    nonisolated static let ns = "/api/v1/namespaces/team-a"
    nonisolated static let podList = """
        {"kind":"PodList","items":[
          {"metadata":{"name":"web-1","namespace":"team-a"},"spec":{"nodeName":"node-a","containers":[{"name":"app"}]},
           "status":{"phase":"Running","containerStatuses":[{"name":"app","ready":true,"restartCount":0,"state":{"running":{}}}]}},
          {"metadata":{"name":"worker-0","namespace":"team-a"},"spec":{"nodeName":"node-b","containers":[{"name":"app"}]},
           "status":{"phase":"Running","containerStatuses":[{"name":"app","ready":false,"restartCount":7,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}
        ]}
        """
    nonisolated static let deployment = #"""
        {"metadata": {"name": "web", "namespace": "team-a", "generation": 2},
         "spec": {"replicas": 3, "template": {"spec": {"containers": [{"image": "web:1"}]}}},
         "status": {"readyReplicas": 2, "updatedReplicas": 3, "availableReplicas": 2, "observedGeneration": 2}}
        """#
    nonisolated static let events = #"""
        {"items": [
          {"metadata": {"name": "e1", "namespace": "team-a"}, "type": "Warning", "reason": "BackOff", "message": "Back-off restarting failed container",
           "involvedObject": {"kind": "Pod", "name": "worker-0"}, "count": 4, "lastTimestamp": "2026-11-17T10:03:00Z"},
          {"metadata": {"name": "e2", "namespace": "team-a"}, "type": "Normal", "reason": "Pulled", "message": "Pulled image",
           "involvedObject": {"kind": "Pod", "name": "web-1"}, "lastTimestamp": "2026-11-17T10:04:00Z"}]}
        """#

    nonisolated static let cases: [Case] = [
        Case(fetcher: "k8s.pods", input: [:], routes: [ns + "/pods": Self.podList],
             path: ns + "/pods") { $0["count"] == 2 && $0["namespace"] == "team-a" && $0["pods"]?[1]?["status"] == "CrashLoopBackOff" },
        Case(fetcher: "k8s.namespaces", input: [:], routes: ["/api/v1/namespaces": #"{"items": [{"metadata": {"name": "team-a"}, "status": {"phase": "Active"}}]}"#],
             path: "/api/v1/namespaces") { $0["items"]?[0]?["name"] == "team-a" && $0["items"]?[0]?["status"] == "Active" },
        Case(fetcher: "k8s.list", input: ["kind": "deploy"], routes: ["/apis/apps/v1/namespaces/team-a/deployments": "{\"items\": [\(deployment)]}"],
             path: "/apis/apps/v1/namespaces/team-a/deployments") { $0["items"]?[0]?["ready"] == "2/3" && $0["items"]?[0]?["images"] == ["web:1"] },
        Case(fetcher: "k8s.describe", input: ["kind": "secret", "name": "db"],
             routes: [ns + "/secrets/db": #"{"metadata": {"name": "db", "managedFields": [{}]}, "data": {"password": "c2VjcmV0"}}"#, ns + "/events": events],
             path: ns + "/secrets/db") { $0["object"]?["data"]?["password"] != nil && $0["object"]?["metadata"]?["managedFields"] == nil
                 && !$0.jsonString().contains("c2VjcmV0") },
        Case(fetcher: "k8s.logs", input: ["pod": "web-1", "tail": 50],
             routes: [ns + "/pods/web-1/log": "2026-11-17T10:00:00Z starting\n2026-11-17T10:00:01Z GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789"],
             path: ns + "/pods/web-1/log") { $0["text"]?.string?.contains("starting") == true && $0["text"]?.string?.contains("ghp_") == false },
        Case(fetcher: "k8s.events", input: [:], routes: [ns + "/events": events],
             path: ns + "/events") { $0["items"]?.array?.count == 1 && $0["items"]?[0]?["reason"] == "BackOff" && $0["items"]?[0]?["object"] == "Pod/worker-0" },
        Case(fetcher: "k8s.top_pods", input: [:],
             routes: ["/apis/metrics.k8s.io/v1beta1/namespaces/team-a/pods": #"{"items": [{"metadata": {"name": "web-1", "namespace": "team-a"}, "containers": [{"name": "app", "usage": {"cpu": "12m", "memory": "64Mi"}}]}]}"#],
             path: "/apis/metrics.k8s.io/v1beta1/namespaces/team-a/pods") { $0["items"]?[0]?["containers"]?[0]?["cpu"] == "12m" },
        Case(fetcher: "k8s.rollout_status", input: ["name": "web"], routes: ["/apis/apps/v1/namespaces/team-a/deployments/web": deployment],
             path: "/apis/apps/v1/namespaces/team-a/deployments/web") { $0["done"] == false && $0["desired"] == 3 && $0["available"] == 2 },
        Case(fetcher: "k8s.api", input: ["path": "/api/v1/nodes"], routes: ["/api/v1/nodes": #"{"items": [{"metadata": {"name": "node-a"}}]}"#],
             path: "/api/v1/nodes") { $0["items"]?[0]?["metadata"]?["name"] == "node-a" },
    ]

    let stub = "k8s-\(UUID().uuidString.prefix(8).lowercased()).test"
    let dash: TestHost
    let k8s: KubernetesIntegration

    init() throws {
        k8s = try makeIntegration(singleContext(host: stub, user: ["token: t0ken"], namespace: "team-a"))
        dash = try TestHost([k8s])
        dash.start([k8s])
    }

    func serve(_ routes: [String: String]) {
        StubProtocol.serve(stub) { request in (200, Data((routes[request.url?.path ?? ""] ?? "{}").utf8)) }
    }

    func resource(_ fetcher: String) throws -> KubernetesResource {
        try #require(k8s.resources.first { $0.fetcherName == fetcher })
    }

    // MARK: Fetchers and readers

    @Test(arguments: cases)
    func fetcherStoresAndReaderReads(_ c: Case) async throws {
        serve(c.routes)
        let resource = try resource(c.fetcher)

        let before = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(before["fetched"] == false && before["rows"] == [])
        #expect(before["refresh"]?["fetcher"] == .string(c.fetcher))

        let receipt = try await dash.fetch(c.fetcher, c.input)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0)
        #expect(receipt["keys"]?.array?.count == 1 && receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
        #expect(receipt["synced_at"]?.string != nil)
        #expect(receipt["read_with"]?.string?.hasPrefix(resource.readerName + " {") == true)
        let sent = StubProtocol.requests(stub)
        #expect(sent.contains { $0.url?.path == c.path })
        #expect(sent.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken" })

        let answer = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(c.check(answer), "\(answer.jsonString())")
        #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)
        #expect(answer["refresh"]?["fetcher"] == .string(c.fetcher))

        let again = try await dash.fetch(c.fetcher, c.input)
        #expect(again["stored"] == 0 && again["unchanged"] == 1)
        let stored = dash.testSynced.records(kind: resource.kind, scope: k8s.storeScope)
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { !$0.value.jsonString().contains("ghp_") && !$0.value.jsonString().contains("t0ken") && $0.source == "kubernetes" })
    }

    @Test func readersSayWhenDataIsStale() async throws {
        serve([Self.ns + "/pods": Self.podList, "/api/v1/namespaces": #"{"items": []}"#])
        _ = try await dash.fetch("k8s.pods", [:])
        _ = try await dash.fetch("k8s.namespaces", [:])
        k8s.now = { .now.addingTimeInterval(2 * 60) }
        let pods = try #require(try await dash.runTool("k8s_list_pods", [:]))
        #expect(pods["stale"] == true && pods["count"] == 2)
        #expect(pods["refresh"] == ["fetcher": "k8s.pods", "input": ["namespace": "team-a"]])
        // Namespaces stay fresh for an hour.
        #expect(try await dash.runTool("k8s_namespaces", [:])?["stale"] == false)
    }

    @Test func inputsAreNormalizedAndChecked() async throws {
        serve(["/apis/apps/v1/namespaces/team-a/deployments": "{\"items\": [\(Self.deployment)]}", "/api/v1/pods": Self.podList])
        let receipt = try await dash.fetch("k8s.list", ["kind": "deploy"])
        #expect(receipt["read_with"] == #"k8s_list {"kind":"deployments","namespace":"team-a"}"#)
        // The same question asked another way reads the same record.
        let answer = try #require(try await dash.runTool("k8s_list", ["kind": " Deployments ", "namespace": "team-a", "extra": 1]))
        #expect(answer.object?.keys.contains("fetched") == false && answer["items"]?.array?.count == 1)
        // "*" and "all" are every namespace.
        _ = try await dash.fetch("k8s.pods", ["namespace": "*"])
        #expect(StubProtocol.requests(stub).last?.url?.path == "/api/v1/pods")
        #expect(try await dash.runTool("k8s_list_pods", ["namespace": "all"])?["count"] == 2)
        // Selectors reach the API encoded.
        _ = try await dash.fetch("k8s.pods", ["namespace": "all", "labelSelector": "app in (web,worker),tier!=cache"])
        let url = try #require(StubProtocol.requests(stub).last?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "labelSelector" }?.value == "app in (web,worker),tier!=cache")

        let before = StubProtocol.requests(stub).count
        await #expect(throws: ToolError("Give pod.")) { _ = try await dash.runTool("k8s_logs", [:]) }
        await #expect(throws: ToolError.self) { _ = try await dash.fetch("k8s.pods", ["namespace": "../secrets"]) }
        await #expect(throws: ToolError.self) { _ = try await dash.fetch("k8s.logs", ["pod": "../../secrets/db"]) }
        await #expect(throws: ToolError.self) { _ = try await dash.fetch("k8s.describe", ["kind": "secret", "name": "db/../x"]) }
        await #expect(throws: ToolError.self) { _ = try await dash.fetch("k8s.list", ["kind": "widgets"]) }
        await #expect(throws: ToolError.self) { _ = try await dash.runTool("k8s_api_read", ["path": "/api/v1/pods?watch=true"]) }
        #expect(StubProtocol.requests(stub).count == before)
    }

    @Test func fetchersExplainAMissingConnection() async throws {
        let eks = try makeIntegration(Kubeconfigs.eks)
        let host = try TestHost([eks])
        host.start([eks])
        await #expect(throws: ToolError.self) { _ = try await host.fetch("k8s.api", ["path": "/api/v1/pods"]) }
        #expect(try await host.runTool("k8s_api_read", ["path": "/api/v1/pods"])?["fetched"] == false)
    }

    @Test func recordsArePerContext() async throws {
        serve([Self.ns + "/pods": Self.podList])
        _ = try await dash.fetch("k8s.pods", [:])
        #expect(k8s.storeScope == "k8s:ctx")
        #expect(dash.testSynced.records(kind: "k8s.pods", scope: "k8s:other").isEmpty)
        #expect(try await dash.runTool("k8s_list_pods", [:])?["count"] == 2)
    }

    @Test func queryAnswersExpireAfterADayAndBigOnesAreCapped() async throws {
        serve([Self.ns + "/events": Self.events, "/api/v1/nodes": "{\"blob\":\"\(String(repeating: "a", count: 90_000))\(String(repeating: "\\u00e9", count: 30_000))\"}"])
        _ = try await dash.fetch("k8s.events", [:])
        k8s.now = { .now.addingTimeInterval(2 * 86_400) }
        _ = try await dash.fetch("k8s.events", ["warningsOnly": false])
        #expect(dash.testSynced.records(kind: "k8s.events", scope: k8s.storeScope).map { $0.value["input"]?["warningsOnly"] } == [false])
        _ = try await dash.fetch("k8s.api", ["path": "/api/v1/nodes"])
        let stored = try #require(dash.testSynced.records(kind: "k8s.api", scope: k8s.storeScope).first)
        #expect(stored.value.jsonString().utf8.count < 201_000)
    }

    // MARK: No network for Dashii and agents

    @Test func noToolDashiiGetsCallsTheCluster() async throws {
        let forDashii = k8s.tools.filter(\.isForDashii)
        let values: [String: JSONValue] = ["kind": "deploy", "name": "web", "pod": "web-1", "path": "/api/v1/nodes"]
        #expect(await NetworkSentinel.requests(running: forDashii, values: values) == [])
        // With data stored, the readers still only read.
        serve([Self.ns + "/pods": Self.podList, "/apis/apps/v1/namespaces/team-a/deployments/web": Self.deployment])
        _ = try await dash.fetch("k8s.pods", [:])
        _ = try await dash.fetch("k8s.rollout_status", ["name": "web"])
        #expect(await NetworkSentinel.requests(running: forDashii, values: values) == [])
        // The fetchers do reach the cluster (through the integration's own TLS session): the sentinel sees them.
        let fetched = await NetworkSentinel.requests(running: [DashiiTool(name: "probe", description: "") { [k8s] _ in
            try await k8s.fetch(try #require(k8s.resources.first { $0.what == "namespaces" }), [:])
        }])
        #expect(fetched == ["probe: GET \(stub)/api/v1/namespaces"])
    }

    @Test func toolsFetchersAndVerbsLineUp() throws {
        let tools = k8s.tools
        let forDashii = tools.filter(\.isForDashii).map(\.name)
        #expect(forDashii == ["k8s_contexts"] + k8s.resources.map(\.readerName))
        #expect(!forDashii.contains("k8s_get"))
        #expect(tools.filter { !$0.isForDashii }.map(\.name) == ["k8s_rollout_restart", "k8s_scale"])
        #expect(tools.filter { !$0.isForDashii }.allSatisfy { $0.writesRemotely && $0.requiresApproval })
        #expect(tools.allSatisfy { !$0.callsService })
        let fetchers = k8s.fetchers.map(\.name)
        #expect(fetchers.count == k8s.resources.count && fetchers.allSatisfy { $0.hasPrefix("k8s.") } && Set(fetchers).count == fetchers.count)
        // Every verb names a tool; only rollout restart names a write (DashQL only runs the caller's tools).
        #expect(k8s.verbs.allSatisfy { verb in tools.contains { $0.name == verb.tool } })
        #expect(k8s.verbs.filter { !forDashii.contains($0.tool) }.map(\.tool) == ["k8s_rollout_restart"])
        #expect(k8s.datasets.map(\.name) == ["k8s_events", "k8s_objects"])
    }

    @Test func datasetsReadStoredAnswers() async throws {
        serve([Self.ns + "/events": Self.events, "/apis/apps/v1/namespaces/team-a/deployments": "{\"items\": [\(Self.deployment)]}"])
        let events = try #require(k8s.datasets.first { $0.name == "k8s_events" })
        #expect(try await events.rows(nil).isEmpty)
        _ = try await dash.fetch("k8s.events", [:])
        _ = try await dash.fetch("k8s.events", ["warningsOnly": false])
        let rows = try await events.rows(nil)
        #expect(rows.map { $0["reason"] } == ["Pulled", "BackOff"])
        #expect(rows.allSatisfy { $0["context"] == "ctx" && $0["namespace"] == "team-a" && $0["stale"] == false && $0["synced_at"]?.string != nil })
        _ = try await dash.fetch("k8s.list", ["kind": "deploy"])
        let objects = try await #require(k8s.datasets.first { $0.name == "k8s_objects" }).rows(nil)
        #expect(objects.first?["kind"] == "deployments" && objects.first?["name"] == "web" && objects.first?["ready"] == "2/3")
    }
}
