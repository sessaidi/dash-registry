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
