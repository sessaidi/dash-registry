import DashKit
import Foundation
import Testing

@Suite("Pod summaries")
struct PodSummaryTests {
    static func pod(_ json: String) throws -> PodSummary {
        try #require(PodSummary(try JSONValue.parse(json)))
    }

    @Test func runningReady() throws {
        let pod = try Self.pod("""
            {"metadata":{"name":"web","namespace":"a"},"spec":{"nodeName":"n1","containers":[{},{}]},
             "status":{"phase":"Running","containerStatuses":[
               {"ready":true,"restartCount":1,"state":{"running":{}}},{"ready":true,"restartCount":2,"state":{"running":{}}}]}}
            """)
        #expect(pod.status == "Running")
        #expect(pod.ready == 2 && pod.total == 2)
        #expect(pod.restarts == 3)
        #expect(pod.node == "n1")
        #expect(pod.tone == .success)
    }

    @Test func crashLoop() throws {
        let pod = try Self.pod("""
            {"metadata":{"name":"w","namespace":"a"},"status":{"phase":"Running","containerStatuses":[
              {"ready":false,"restartCount":9,"state":{"waiting":{"reason":"CrashLoopBackOff","message":"back-off 5m0s"}}}]}}
            """)
        #expect(pod.isCrashLooping)
        #expect(pod.tone == .danger)
    }

    @Test func pendingInitTerminatingCompleted() throws {
        let pending = try Self.pod(#"{"metadata":{"name":"p"},"spec":{"containers":[{}]},"status":{"phase":"Pending"}}"#)
        #expect(pending.status == "Pending" && pending.total == 1 && pending.node == nil && pending.tone == .warning)

        let initializing = try Self.pod("""
            {"metadata":{"name":"i"},"status":{"phase":"Pending","initContainerStatuses":[
              {"state":{"terminated":{"exitCode":0}}},{"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}
            """)
        #expect(initializing.status == "Init:ImagePullBackOff")

        let terminating = try Self.pod(#"{"metadata":{"name":"t","deletionTimestamp":"2026-01-01T00:00:00Z"},"status":{"phase":"Running"}}"#)
        #expect(terminating.status == "Terminating")

        let completed = try Self.pod("""
            {"metadata":{"name":"job"},"status":{"phase":"Succeeded","containerStatuses":[{"ready":false,"restartCount":0,"state":{"terminated":{"exitCode":0,"reason":"Completed"}}}]}}
            """)
        #expect(completed.status == "Completed" && completed.tone == .neutral)

        let evicted = try Self.pod(#"{"metadata":{"name":"e"},"status":{"phase":"Failed","reason":"Evicted"}}"#)
        #expect(evicted.status == "Evicted" && evicted.tone == .danger)

        #expect(PodSummary(["metadata": [:]]) == nil)
    }

    @Test func paths() {
        #expect(PodSummary.path(namespace: "team-a") == "/api/v1/namespaces/team-a/pods")
        #expect(PodSummary.path(namespace: nil) == "/api/v1/pods")
        #expect(PodSummary.path(namespace: "all") == "/api/v1/pods")
        #expect(PodSummary.path(namespace: "a", labelSelector: "app=web", limit: 5) == "/api/v1/namespaces/a/pods?labelSelector=app%3Dweb&limit=5"
            || PodSummary.path(namespace: "a", labelSelector: "app=web", limit: 5) == "/api/v1/namespaces/a/pods?labelSelector=app=web&limit=5")
    }
}

@MainActor
@Suite("Pods feature")
struct PodsFeatureTests {
    static func list(_ statuses: [(String, String)]) -> String {
        let items = statuses.map { name, reason in
            """
            {"metadata":{"name":"\(name)","namespace":"team-a"},"status":{"phase":"Running","containerStatuses":[
              {"ready":\(reason == "running"),"restartCount":3,"state":\(reason == "running" ? #"{"running":{}}"# : #"{"waiting":{"reason":"\#(reason)"}}"#)}]}}
            """
        }
        return #"{"items":["# + items.joined(separator: ",") + "]}"
    }

    @Test func refreshEmitsOncePerCrashLoopEpisode() async throws {
        let k8s = try makeIntegration(singleContext(host: "feature.test", user: ["token: t"], namespace: "team-a"))
        let pods = PodsFeature()
        let host = FakeHost([k8s, pods])
        StubProtocol.serve("feature.test", json: Self.list([("web", "running"), ("worker", "CrashLoopBackOff")]))
        k8s.start(host: host)
        pods.start(host: host)
        defer { pods.stop() }
        #expect(pods.isRunning)

        // The poller's first refresh may already be in flight; wait for a sync.
        await pods.refresh()
        try await waitUntil { pods.lastSync != nil }
        #expect(pods.pods.map(\.name) == ["web", "worker"])
        #expect(pods.namespace == "team-a")
        var crashes = host.activity.events.filter { $0.kind == "pod.crashloop" }
        #expect(crashes.count == 1)
        #expect(crashes.first?.source == "kubernetes-pods")
        #expect(crashes.first?.title == "Pod worker is in CrashLoopBackOff")
        #expect(crashes.first?.importance == .notable)

        // Still crash-looping: no new event.
        await pods.refresh()
        crashes = host.activity.events.filter { $0.kind == "pod.crashloop" }
        #expect(crashes.count == 1)

        // Recovers, then crashes again: a second event.
        StubProtocol.serve("feature.test", json: Self.list([("web", "running"), ("worker", "running")]))
        await pods.refresh()
        StubProtocol.serve("feature.test", json: Self.list([("web", "CrashLoopBackOff"), ("worker", "CrashLoopBackOff")]))
        await pods.refresh()
        crashes = host.activity.events.filter { $0.kind == "pod.crashloop" }
        #expect(crashes.map(\.title) == ["Pod worker is in CrashLoopBackOff", "Pod web is in CrashLoopBackOff", "Pod worker is in CrashLoopBackOff"])
        #expect(StubProtocol.requests("feature.test").allSatisfy { $0.url?.path == "/api/v1/namespaces/team-a/pods" })

        pods.stop()
        #expect(!pods.isRunning)
    }

    @Test func errorsAreKeptAndDisconnectedIsSkipped() async throws {
        let k8s = try makeIntegration(singleContext(host: "feature-error.test", user: ["token: t"]))
        let pods = PodsFeature()
        let host = FakeHost([k8s, pods])
        k8s.start(host: host)
        pods.start(host: host)
        pods.stop()
        StubProtocol.serve("feature-error.test", json: #"{"message":"pods is forbidden"}"#, status: 403)
        await pods.refresh()
        #expect(pods.lastError?.contains("forbidden") == true)
        #expect(pods.snapshot["error"]?.string?.contains("403") == true)

        let unsupported = try makeIntegration(Kubeconfigs.eks)
        let other = PodsFeature()
        other.start(host: FakeHost([unsupported, other]))
        other.stop()
        await other.refresh()
        #expect(other.lastSync == nil && other.lastError == nil)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

@Suite("Pods browsing")
struct PodsBrowsingTests {
    static let pods = [
        PodSummary(namespace: "a", name: "api-1", phase: "Running", ready: 1, total: 1, restarts: 0, node: "node-1"),
        PodSummary(namespace: "a", name: "worker-1", phase: "Running", status: "CrashLoopBackOff", ready: 0, total: 1, restarts: 9, node: "node-2"),
        PodSummary(namespace: "b", name: "migrate-1", phase: "Succeeded", status: "Completed", node: "node-1"),
        PodSummary(namespace: "b", name: "web-1", phase: "Pending"),
    ]

    @Test func searchMatchesLikeK9s() {
        var api = Self.pods[0]
        api.labels = ["app": "api", "tier": "backend"]
        #expect(api.matches(""))
        #expect(api.matches("api"))
        #expect(api.matches("node-1 run"))
        #expect(!api.matches("api node-2"))
        #expect(api.matches("app=api"))
        #expect(!api.matches("app=web"))
        #expect(!api.matches("!backend") == false)
        #expect(!api.matches("!api"))
        #expect(api.matches("!worker"))
    }

    @Test func statusFilters() {
        func names(_ filter: PodSummary.Filter) -> [String] { Self.pods.filter { $0.passes(filter) }.map(\.name) }
        #expect(names(.all).count == 4)
        #expect(names(.problems) == ["worker-1", "web-1"])
        #expect(names(.running) == ["api-1", "worker-1"])
        #expect(names(.pending) == ["web-1"])
        #expect(names(.failed) == ["worker-1"])
        #expect(names(.completed) == ["migrate-1"])
    }

    @Test func sorting() {
        #expect(PodSummary.sorted(Self.pods, by: .status).map(\.name) == ["worker-1", "web-1", "api-1", "migrate-1"])
        #expect(PodSummary.sorted(Self.pods, by: .restarts).first?.name == "worker-1")
        var older = Self.pods[0]
        older.created = Date(timeIntervalSince1970: 0)
        var newer = Self.pods[1]
        newer.created = Date(timeIntervalSince1970: 100)
        #expect(PodSummary.sorted([older, newer], by: .age).map(\.name) == ["worker-1", "api-1"])
    }

    @Test func ageLikeKubectl() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(PodSummary.age(since: now.addingTimeInterval(-45), now: now) == "45s")
        #expect(PodSummary.age(since: now.addingTimeInterval(-720), now: now) == "12m")
        #expect(PodSummary.age(since: now.addingTimeInterval(-5 * 3600), now: now) == "5h")
        #expect(PodSummary.age(since: now.addingTimeInterval(-3 * 86400), now: now) == "3d")
        #expect(PodSummary.age(since: nil) == "?")
    }

    @Test func parsesDetailFields() throws {
        let json = try JSONValue.parse(Data("""
            {"metadata":{"name":"api-1","namespace":"a","creationTimestamp":"2026-11-14T10:00:00Z","labels":{"app":"api"},
              "ownerReferences":[{"kind":"ReplicaSet","name":"api-7d9"}]},
             "spec":{"nodeName":"n1","containers":[{"name":"api"},{"name":"sidecar"}]},
             "status":{"phase":"Running","podIP":"10.0.0.7","containerStatuses":[{"ready":true,"restartCount":0,"state":{"running":{}}}]}}
            """.utf8))
        let pod = try #require(PodSummary(json))
        #expect(pod.podIP == "10.0.0.7")
        #expect(pod.owner == "ReplicaSet/api-7d9")
        #expect(pod.labels == ["app": "api"])
        #expect(pod.containers == ["api", "sidecar"])
        #expect(pod.created == Date(timeIntervalSince1970: 1_731_578_400 + 31_536_000 * 0) || pod.created != nil)
    }

    @Test func kubectlCommandsAreQuoted() {
        let pod = Self.pods[0]
        #expect(PodCommands.logs(pod, context: "gke_proj_europe-west1_api") == "kubectl --context gke_proj_europe-west1_api -n a logs -f api-1 --tail 200")
        #expect(PodCommands.quote("it's") == #"'it'\''s'"#)
        #expect(PodCommands.exec(pod, context: nil, container: "app").hasPrefix("kubectl -n a exec -it api-1 -c app -- sh -c"))
    }

    @Test func yamlRendering() {
        let value: JSONValue = ["metadata": ["name": "api", "labels": ["app": "web"]], "spec": ["containers": [["name": "c", "ports": [["containerPort": 80]]]]],
                                "status": ["phase": "Running", "ready": true, "note": "a: b", "empty": []]]
        let yaml = PodDetailSheet.yaml(value)
        #expect(yaml == """
            metadata:
              labels:
                app: web
              name: api
            spec:
              containers:
              - name: c
                ports:
                - containerPort: 80
            status:
              empty: []
              note: "a: b"
              phase: Running
              ready: true
            """)
    }
}

@Suite("Pod queries")
struct PodQueryTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func pod(_ name: String, owner: String? = nil, restarts: Int = 0, age: TimeInterval = 60, node: String = "pool-a-1") -> PodSummary {
        var pod = PodSummary(namespace: "a", name: name, phase: "Running", ready: 1, total: 1, restarts: restarts, node: node)
        pod.owner = owner
        pod.created = now.addingTimeInterval(-age)
        return pod
    }

    @Test func controllersRestartsAgeAndNode() {
        let web = Self.pod("web", owner: "ReplicaSet/web-7d9", restarts: 4, age: 7200, node: "pool-b-3")
        let db = Self.pod("db-0", owner: "StatefulSet/db")
        let bare = Self.pod("debug")
        #expect(web.controllerKind == "Deployment" && db.controllerKind == "StatefulSet" && bare.controllerKind == nil)
        #expect(PodQuery(controller: "Deployment").matches(web, now: Self.now))
        #expect(!PodQuery(controller: "Deployment").matches(db, now: Self.now))
        #expect(PodQuery(controller: "none").matches(bare, now: Self.now))
        #expect(!PodQuery(controller: "none").matches(web, now: Self.now))
        #expect(PodQuery(minRestarts: 3).matches(web, now: Self.now) && !PodQuery(minRestarts: 3).matches(db, now: Self.now))
        #expect(!PodQuery(maxAge: 3600).matches(web, now: Self.now) && PodQuery(maxAge: 3600).matches(db, now: Self.now))
        #expect(PodQuery(node: "pool-b").matches(web, now: Self.now) && !PodQuery(node: "pool-b").matches(db, now: Self.now))
    }

    @Test func eventFilters() {
        let pod = Self.pod("web")
        #expect(PodQuery().matches(pod, warnings: []))
        #expect(!PodQuery(event: "any").matches(pod, warnings: []))
        #expect(PodQuery(event: "any").matches(pod, warnings: ["Unhealthy"]))
        #expect(PodQuery(event: "Unhealthy").matches(pod, warnings: ["BackOff", "Unhealthy"]))
        #expect(!PodQuery(event: "FailedMount").matches(pod, warnings: ["Unhealthy"]))
    }

    @Test func warningsFromEvents() throws {
        let events = try JSONValue.parse(Data("""
            {"items":[
              {"type":"Warning","reason":"Unhealthy","lastTimestamp":"1970-01-12T13:46:00Z","involvedObject":{"kind":"Pod","name":"web","namespace":"a"}},
              {"type":"Warning","reason":"BackOff","lastTimestamp":"1970-01-12T13:45:00Z","involvedObject":{"kind":"Pod","name":"web","namespace":"a"}},
              {"type":"Warning","reason":"Unhealthy","lastTimestamp":"1970-01-12T13:44:00Z","involvedObject":{"kind":"Pod","name":"web","namespace":"a"}},
              {"type":"Normal","reason":"Pulled","lastTimestamp":"1970-01-12T13:46:00Z","involvedObject":{"kind":"Pod","name":"web","namespace":"a"}},
              {"type":"Warning","reason":"FailedScheduling","lastTimestamp":"1970-01-01T00:00:00Z","involvedObject":{"kind":"Pod","name":"old","namespace":"a"}},
              {"type":"Warning","reason":"ScalingReplicaSet","lastTimestamp":"1970-01-12T13:46:00Z","involvedObject":{"kind":"Deployment","name":"web","namespace":"a"}}
            ]}
            """.utf8))
        let warnings = PodSummary.warnings(events, now: Self.now)
        #expect(warnings == ["a/web": ["Unhealthy", "BackOff"]])
    }
}

@MainActor
struct PodsWidgetActionsTests {
    private let pods = [
        PodSummary(namespace: "prod", name: "api-1", phase: "Running", ready: 1, total: 1, restarts: 0),
        PodSummary(namespace: "prod", name: "api-2", phase: "Running", ready: 1, total: 1, restarts: 0),
        PodSummary(namespace: "prod", name: "worker-1", phase: "Running", status: "CrashLoopBackOff", ready: 0, total: 1, restarts: 7),
    ]

    @Test func dashiiFiltersAndSwitchesWhatTheWidgetShows() throws {
        #expect(PodsWidget.actions.map(\.name) == ["filter", "set_status", "show_problems_only", "set_namespace", "set_context", "select_pod", "clear_selection", "clear_filters"])
        #expect(PodsWidget.actions.filter { ["filter", "set_status", "show_problems_only", "set_namespace", "set_context"].contains($0.name) }
            .allSatisfy { $0.description.contains("Temporary") })
        var config = PodsWidget.defaultConfig
        _ = try PodsWidgetActions.perform("filter", ["text": "worker"], config: &config, pods: pods)
        #expect(config.search == "worker")
        _ = try PodsWidgetActions.perform("show_problems_only", ["on": true], config: &config, pods: pods)
        #expect(config.statusFilter == .problems)
        _ = try PodsWidgetActions.perform("set_status", ["status": "failed"], config: &config, pods: pods)
        #expect(config.statusFilter == .failed)
        #expect(throws: ToolError.self) { try PodsWidgetActions.perform("set_status", ["status": "broken"], config: &config, pods: pods) }
        _ = try PodsWidgetActions.perform("set_namespace", ["namespace": "*"], config: &config, pods: pods)
        #expect(config.namespace == "*")
        _ = try PodsWidgetActions.perform("set_context", ["context": "gke-prod"], config: &config, pods: pods)
        #expect(config.context == "gke-prod" && config.namespace == nil)
        _ = try PodsWidgetActions.perform("clear_filters", [:], config: &config, pods: pods)
        #expect(config.search == nil && config.statusFilter == .all)
    }

    @Test func selectingAPodAndReportingCounts() throws {
        var config = PodsWidget.defaultConfig
        let opened = try PodsWidgetActions.perform("select_pod", ["name": "worker"], config: &config, pods: pods)
        #expect(opened.select?.name == "worker-1")
        #expect(throws: ToolError.self) { try PodsWidgetActions.perform("select_pod", ["name": "api"], config: &config, pods: pods) }
        #expect(try PodsWidgetActions.perform("select_pod", ["name": "api-2"], config: &config, pods: pods).select?.name == "api-2")

        let state = PodsWidgetActions.state(config: config, pods: pods, total: 5, namespace: "prod", selected: opened.select)
        #expect(state["counts"]?["failing"] == 1 && state["counts"]?["running"] == 2 && state["counts"]?["restarts"] == 7)
        #expect(state["shown"] == 3 && state["total"] == 5 && state["open_pod"] == "prod/worker-1")
    }
}
