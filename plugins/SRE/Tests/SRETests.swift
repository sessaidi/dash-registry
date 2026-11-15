import DashKit
import DashKitTesting
import Foundation
import Testing

/// Stands in for Datadog Monitors, Kubernetes Pods and their read tools, plus one tool that
/// changes things (which the SRE must never call).
@MainActor
final class FakeOps: DashExtension {
    let id = "fake-ops"
    let name = "Fake ops"
    let systemImage = "server.rack"
    let metadata = ExtensionMetadata(version: "1.0.0", summary: "Test.")
    var monitors: [JSONValue] = []
    var pods: [JSONValue] = []
    var calls: [String] = []

    var datasets: [QueryDataset] {
        [QueryDataset(name: "monitors", summary: "") { [weak self] _ in self?.monitors ?? [] },
         QueryDataset(name: "pods", summary: "") { [weak self] _ in self?.pods ?? [] }]
    }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "k8s_events", description: "") { [weak self] _ in
                self?.calls.append("k8s_events")
                return [["object": "Pod/api-1", "reason": "BackOff", "message": "Back-off restarting failed container", "lastSeen": "2026-11-15T10:03:00Z"]]
            },
            DashiiTool(name: "datadog_events", description: "") { [weak self] _ in
                self?.calls.append("datadog_events")
                return ["data": [["attributes": ["title": "Deployed api v1.42", "timestamp": "2026-11-15T10:01:00Z"]]]]
            },
            DashiiTool(name: "datadog_logs_search", description: "") { [weak self] _ in
                self?.calls.append("datadog_logs_search")
                return [["status": "error", "message": "missing key FEATURE_FLAGS_URL"], ["status": "error", "message": "missing key FEATURE_FLAGS_URL"]]
            },
            DashiiTool(name: "k8s_logs", description: "", requiresApproval: true) { [weak self] _ in
                self?.calls.append("k8s_logs (approval)")
                return "should not be called"
            },
        ]
    }
}

@MainActor
@Suite(.serialized)
struct SRETests {
    func make() throws -> (SREFeature, FakeOps, TestHost) {
        let sre = SREFeature(), ops = FakeOps()
        let host = try TestHost([sre, ops])
        host.start([sre, ops])
        return (sre, ops, host)
    }

    static let alerting: JSONValue = ["id": 1201, "name": "api 5xx rate", "status": "Alert", "service": "api", "env": "prod"]
    static let crashing: JSONValue = ["name": "api-1", "namespace": "bill-eu", "status": "CrashLoopBackOff", "restarts": 14, "healthy": false]

    @Test func statusListsWhatNeedsAttentionWorstFirst() async throws {
        let (_, ops, host) = try make()
        ops.monitors = [["id": 2, "name": "latency", "status": "Warn"], Self.alerting, ["id": 3, "name": "fine", "status": "OK"]]
        ops.pods = [Self.crashing, ["name": "ok", "namespace": "x", "status": "Running", "healthy": true]]
        let status = try #require(await host.runTool("sre_status"))
        #expect(status["monitors"]?.array?.map { $0["title"]?.string } == ["api 5xx rate", "latency"])
        #expect(status["unhealthy_pods"]?.array?.first?["id"] == "bill-eu/api-1")
        #expect(status["quiet"] == false && status["sources"] == ["datadog", "kubernetes"])
    }

    @Test func investigateGathersEvidenceAndAsksASmallerModel() async throws {
        let (_, ops, host) = try make()
        ops.monitors = [Self.alerting]
        ops.pods = [Self.crashing]
        host.testDashii.reply = #"{"summary":"v1.42 broke api","hypotheses":[{"cause":"v1.42 misses a config key","likelihood":0.8,"evidence":["e1","e3","e4"],"nextCheck":"logs of api-1"}]}"#
        let result = try #require(await host.runTool("sre_investigate", ["symptom": "api 5xx", "namespace": "bill-eu", "service": "api"]))
        let sources = result["evidence"]?.array?.compactMap { $0["source"]?.string } ?? []
        #expect(sources == ["datadog monitor 1201", "pod bill-eu/api-1", "k8s event Pod/api-1", "datadog event"])
        #expect(result["analysis"]?["hypotheses"]?[0]?["likelihood"] == 0.8)
        let call = try #require(host.testDashii.calls.last)
        #expect(call.prompt.contains("Deployed api v1.42") && call.source == "extension.sre/root_cause")
    }

    @Test func noEvidenceNeedsNoModel() async throws {
        let sre = SREFeature()
        let host = try TestHost([sre])
        host.start([sre])
        let result = try #require(await host.runTool("sre_investigate", ["symptom": "is prod ok?"]))
        #expect(result["analysis"]?.string?.hasPrefix("No evidence") == true)
        #expect(host.testDashii.calls.isEmpty)
        #expect(result["gaps"]?.array?.isEmpty == false)
    }

    @Test func logsAreDigestedAndToolsThatChangeThingsAreNeverUsed() async throws {
        let (_, ops, host) = try make()
        host.testDashii.reply = #"{"summary":"Config key missing.","patterns":[{"pattern":"missing key <key>","count":2,"severity":"error","example":"missing key FEATURE_FLAGS_URL"}]}"#
        let digest = try #require(await host.runTool("sre_logs", ["source": "datadog", "query": "service:api status:error"]))
        #expect(digest["lines"] == 2 && digest["patterns"]?[0]?["count"] == 2)
        await #expect(throws: (any Error).self) { try await host.runTool("sre_logs", ["source": "kubernetes", "pod": "api-1"]) }
        #expect(!ops.calls.contains("k8s_logs (approval)"))
    }

    @Test func oncallSkipsQuietScheduledRunsAndWakesOnAlerts() async throws {
        let (_, ops, host) = try make()
        let precheck = try #require(SREAgents.oncall.precheck)
        #expect(await precheck(host) == .skip("Nothing alerting and every pod healthy."))
        ops.monitors = [Self.alerting]
        guard case .run(let context) = await precheck(host) else { Issue.record("should run"); return }
        #expect(context.contains("api 5xx rate"))
        #expect(SREAgents.oncall.schedule.events == ["datadog.alert", "pod.crashloop"])
        #expect(SREAgents.oncall.access == .readOnly)
    }

    @Test func severityFunctionIsPublished() async throws {
        let (_, _, host) = try make()
        host.testDashii.reply = #"{"severity":"S2","page":true,"blastRadius":"all api users","reason":"5xx alert on api"}"#
        let rating = try await host.runFunction("sre.severity", input: ["symptom": "api 5xx", "signals": ["api 5xx rate Alert"]])
        #expect(rating["severity"] == "S2" && rating["page"] == true)
    }

    @Test func statusWidgetProviderSnapshots() async throws {
        let (_, ops, host) = try make()
        ops.monitors = [Self.alerting, ["id": 2, "name": "latency", "status": "Warn"]]
        let loader = WidgetSnapshotLoader(provider: StatusProvider(host: host))
        await loader.load(.init(criticalOnly: true))
        #expect(loader.snapshot?.signals.monitors.map(\.title) == ["api 5xx rate"])
        #expect(loader.snapshot?.level == .down)
        #expect(StatusSnapshot.sample.level == .down)
    }

    @Test func verbsAndDatasets() throws {
        let sre = SREFeature()
        #expect(sre.verbs.map(\.usage).contains("sre investigate <symptom> [key=value…]"))
        #expect(sre.datasets.map(\.name) == ["signals"])
        #expect(Set(sre.verbs.map(\.tool)).isSubset(of: Set(sre.tools.map(\.name))))
    }
}
