import DashKit
import DashKitUI
import Foundation
import Testing
import WorkspaceKit

/// The cluster most tests start from: two of the user's workspaces (one stale) and a colleague's.
func standardCluster() -> FakeCluster {
    FakeCluster([
        .init(name: "checkout", deployedBy: "sadik", created: .daysAgo(3), deployed: .daysAgo(1), branch: "feat/checkout"),
        .init(name: "old-search", deployedBy: "sadik", created: .daysAgo(40), deployed: .daysAgo(10), node: "gke-workspaces-node-legacy-1"),
        .init(name: "papi-perf", deployedBy: "sadik", created: .daysAgo(60), persist: true, node: "gke-workspaces-standard-9", region: "eu"),
        .init(name: "epg", deployedBy: "jrivera", created: .daysAgo(2), deployed: .daysAgo(0.1)),
    ])
}

@MainActor
@Suite("Workspaces feature")
struct WorkspacesFeatureTests {
    @Test func identityMatchesTheBuiltInFeature() {
        let feature = WorkspacesFeature(defaults: UserDefaults(suiteName: "workspaces-tests-\(UUID().uuidString)")!)
        #expect(feature.id == "workspaces")
        #expect(feature.requires == ["gcp", "kubernetes", "docker", "github", "agents"])
        #expect(feature.layer == .feature)
        #expect(feature.widgets.map(\.kind) == ["workspaces.list", "workspaces.train"])
        #expect(feature.tools.map(\.name) == [
            "workspaces_list", "workspaces_for_branch", "workspace_status", "workspaces_clean_candidates", "workspace_set_persist", "workspace_delete", "workspace_deploy_image",
            "workspace_profiles", "workspace_create", "workspace_deploy_worktree", "workspace_config_changes", "workspace_apply_config",
            "workspace_diagnose", "workspace_logs", "workspace_cloud_logs", "workspace_commands",
            "workspace_deployments", "workspace_pods", "workspace_containers", "workspace_events", "workspace_findings", "workspace_nodes",
            "workspace_metrics", "workspace_config", "workspace_env", "workspace_set_env", "workspace_restart", "workspace_link_worktree", "workspace_train",
        ])
        // Changes to the cluster are remote writes: Dash never gives them to Claude.
        #expect(feature.tools.filter(\.writesRemotely).map(\.name) == [
            "workspace_set_persist", "workspace_delete", "workspace_deploy_image", "workspace_create", "workspace_deploy_worktree", "workspace_apply_config",
            "workspace_set_env", "workspace_restart",
        ])
        #expect(feature.agents.map(\.id) == ["doctor"] && feature.agents[0].access == .readOnly)
        #expect(WorkspacesPlugin.makeExtensions().map(\.id) == ["workspaces"])
    }

    @Test func preferencesUseTheBuiltInKeys() {
        let defaults = UserDefaults(suiteName: "workspaces-tests-\(UUID().uuidString)")!
        defaults.set("qa", forKey: "workspaces.env")
        defaults.set("eu", forKey: "workspaces.region")
        defaults.set("someone", forKey: "workspaces.username")
        defaults.set(5, forKey: "workspaces.poll")
        let feature = WorkspacesFeature(defaults: defaults)
        #expect(feature.env == .qa && feature.region == .eu && feature.username == "someone" && feature.pollMinutes == 5)

        feature.env = .dev
        feature.region = .us
        feature.username = "sadik"
        feature.pollMinutes = 10
        #expect(defaults.string(forKey: "workspaces.env") == "dev")
        #expect(defaults.string(forKey: "workspaces.region") == "us")
        #expect(defaults.string(forKey: "workspaces.username") == "sadik")
        #expect(defaults.integer(forKey: "workspaces.poll") == 10)

        let fresh = WorkspacesFeature(defaults: UserDefaults(suiteName: "workspaces-tests-\(UUID().uuidString)")!)
        #expect(fresh.env == .dev && fresh.region == .us && fresh.pollMinutes == 2 && fresh.username == NSUserName())
    }

    @Test func refreshLoadsWorkspacesWithTheGCPToken() async throws {
        let cluster = standardCluster()
        let (feature, _) = makeFeature(cluster)
        await feature.refresh()

        #expect(feature.lastError == nil)
        #expect(feature.lastSync != nil)
        #expect(!feature.isLoading)
        #expect(feature.workspaces.map(\.name) == ["checkout", "epg", "old-search", "papi-perf"])
        #expect(feature.workspaces.map(\.nodePool) == [.spot, .spot, .legacy, .standard])
        #expect(feature.visible(onlyMine: true).map(\.name) == ["checkout", "old-search", "papi-perf"])
        #expect(feature.visible(onlyMine: false).count == 4)
        #expect(!cluster.requests.isEmpty)
        #expect(cluster.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(FakeGCP.token)" })
    }

    @Test func clientIsReusedUntilEnvOrRegionChanges() async throws {
        let cluster = standardCluster()
        let (feature, _) = makeFeature(cluster)
        await feature.refresh()
        await feature.refresh()
        #expect(cluster.connectCount == 1)

        let client = try await feature.client()
        #expect(client.env == .dev && client.region == .us)
        feature.region = .eu
        #expect(feature.workspaces.isEmpty)
        #expect(try await feature.client().region == .eu)
        #expect(cluster.connectCount >= 2)
    }

    @Test func withoutGoogleCloudNothingIsFetched() async throws {
        let cluster = standardCluster()
        let (feature, _) = makeFeature(cluster, gcp: FakeGCP(isConnected: false))
        await feature.refresh()
        #expect(feature.workspaces.isEmpty && feature.lastSync == nil && feature.lastError == nil)
        #expect(cluster.requests.isEmpty)
        await #expect(throws: ToolError("Connect Google Cloud in Settings › Integrations.")) {
            _ = try await feature.tool("workspaces_list").run([:])
        }
    }

    @Test func refreshFailureIsReportedAndPrepareThrows() async throws {
        let (feature, host) = makeFeature(standardCluster(), gcp: FakeGCP(token: nil))
        await feature.refresh()
        #expect(feature.lastError == "The Google Cloud integration didn't provide a token.")
        await #expect(throws: ToolError("The Google Cloud integration didn't provide a token.")) {
            try await feature.prepare(host: host)
        }
    }

    @Test func describeExplainsUnreachableClusters() {
        #expect(WorkspacesFeature.describe(URLError(.timedOut)).hasPrefix("Can't reach the cluster (timed out)."))
        #expect(WorkspacesFeature.describe(URLError(.cannotConnectToHost)).contains("connection failed"))
        #expect(WorkspacesFeature.describe(WorkspaceKitError.notAWorkspace("x")) == "x is not a workspace.")
    }

    // MARK: Tools

    @Test func listTool() async throws {
        let (feature, _) = makeFeature(standardCluster())
        let all = try await feature.tool("workspaces_list").run([:])
        #expect(all.array?.count == 4)
        let mine = try #require(try await feature.tool("workspaces_list").run(["mine": true]).array)
        #expect(mine.compactMap { $0["name"]?.string } == ["checkout", "old-search", "papi-perf"])

        let checkout = mine[0]
        #expect(checkout["deployed_by"]?.string == "sadik")
        #expect(checkout["node_pool"]?.string == "spot")
        #expect(checkout["persist"]?.bool == false)
        #expect(checkout["git_branch"]?.string == "feat/checkout")
        #expect(checkout["region"]?.string == "us")
        #expect(checkout["url"]?.string == "https://checkout.backend-workspace.dev-01.fubo.tv")
        #expect(checkout["deployed_at"]?.string != nil && checkout["created_at"]?.string != nil)
        #expect(mine[2]["url"]?.string == "https://papi-perf.backend-workspace-eu.dev-01.fubo.tv")
        #expect(mine[2]["deployed_at"] == .null)

        await #expect(throws: ToolError.self) { _ = try await feature.tool("workspaces_list").run(["mine": "yes"]) }
    }

    @Test func statusTool() async throws {
        let (feature, _) = makeFeature(standardCluster())
        let status = try await feature.tool("workspace_status").run(["name": "checkout"])
        #expect(status["name"]?.string == "checkout")
        let deployment = try #require(status["deployments"]?[0])
        #expect(deployment["name"]?.string == "common-api-gateway")
        #expect(deployment["ready"]?.int == 1 && deployment["desired"]?.int == 2)
        #expect(deployment["images"]?[0]?.string == "us-docker.pkg.dev/fubotv-dev/apps/common-api-gateway:v1")
        let pods = try #require(status["pods"]?.array)
        #expect(pods.count == 2)
        #expect(pods[0]["problem"] == .null && pods[0]["ready"]?.bool == true)
        #expect(pods[1]["problem"]?.string == "CrashLoopBackOff" && pods[1]["restarts"]?.int == 7 && pods[1]["app"]?.string == "papi")
        #expect(status["hostnames"]?.array == [.string("checkout.backend-workspace.dev-01.fubo.tv")])

        await #expect(throws: ToolError.self) { _ = try await feature.tool("workspace_status").run([:]) }
        await #expect(throws: WorkspaceKitError.self) { _ = try await feature.tool("workspace_status").run(["name": "missing"]) }
    }

    @Test func cleanCandidatesTool() async throws {
        let (feature, _) = makeFeature(standardCluster())
        let candidates = try #require(try await feature.tool("workspaces_clean_candidates").run([:]).array)
        // papi-perf is old but persisted; checkout and epg are fresh on spot.
        #expect(candidates.compactMap { $0["name"]?.string } == ["old-search"])
        #expect(candidates[0]["reason"]?.string == "not deployed for over a week")
    }

    @Test func setPersistToolPatchesTheNamespace() async throws {
        let cluster = standardCluster()
        let (feature, _) = makeFeature(cluster)
        #expect(try await feature.tool("workspace_set_persist").run(["name": "checkout", "persist": true]) == "done")
        let patch = try #require(cluster.patches.first)
        #expect(patch.path == "/api/v1/namespaces/checkout")
        #expect(patch.contentType == "application/merge-patch+json")
        #expect(patch.body == ["metadata": ["annotations": ["persist": "true"]]])
        #expect(feature.workspaces.first { $0.name == "checkout" }?.persist == true)
    }

    @Test func deleteToolCancelledByTheUser() async throws {
        let cluster = standardCluster()
        let (feature, host) = makeFeature(cluster, allow: false)
        await #expect(throws: ToolError("The user cancelled.")) {
            _ = try await feature.tool("workspace_delete").run(["name": "checkout"])
        }
        #expect(host.fakePermissions.asked == ["Delete workspace checkout?"])
        #expect(cluster.deletes.isEmpty)
        #expect(host.activity.events.isEmpty)
    }

    @Test func deleteToolDeletesAndWaits() async throws {
        let cluster = standardCluster()
        let (feature, host) = makeFeature(cluster)
        await feature.refresh()
        #expect(try await feature.tool("workspace_delete").run(["name": "checkout"]) == "deleted")
        #expect(cluster.deletes == ["checkout"])
        #expect(feature.busy.isEmpty)
        #expect(!feature.workspaces.map(\.name).contains("checkout"))
        let event = try #require(host.activity.events.last)
        #expect(event.kind == "workspace.deleted" && event.source == "workspaces" && event.importance == .notable)
        #expect(event.title == "Workspace checkout deleted")
    }

    @Test func deleteWithoutConfirmationSkipsTheDialog() async throws {
        let cluster = standardCluster()
        let (feature, host) = makeFeature(cluster, allow: false)
        try await feature.delete("epg", confirm: false)
        #expect(host.fakePermissions.asked.isEmpty)
        #expect(cluster.deletes == ["epg"])
    }

    @Test func deployToolPatchesAndWaitsForTheImage() async throws {
        let cluster = standardCluster()
        let (feature, host) = makeFeature(cluster)
        let image = "us-docker.pkg.dev/fubotv-dev/apps/common-api-gateway:abc123"
        #expect(try await feature.tool("workspace_deploy_image").run(["name": "checkout", "app": "common-api-gateway", "image": .string(image)]) == "deployed")

        #expect(cluster.patches.map(\.path) == ["/api/v1/namespaces/checkout", "/apis/apps/v1/namespaces/checkout/deployments/common-api-gateway"])
        #expect(cluster.patches[0].body["metadata"]?["annotations"]?["deployed_at"]?.string != nil)
        let deployment = cluster.patches[1]
        #expect(deployment.contentType == "application/strategic-merge-patch+json")
        #expect(deployment.body["spec"]?["template"]?["spec"]?["containers"] == [["name": "common-api-gateway", "image": .string(image)]])
        #expect(feature.busy.isEmpty)
        let event = try #require(host.activity.events.last)
        #expect(event.kind == "workspace.deployed" && event.title == "common-api-gateway deployed to checkout" && event.detail == image)

        await #expect(throws: ToolError.self) { _ = try await feature.tool("workspace_deploy_image").run(["name": "checkout"]) }
    }

    @Test func toolsReturnNothingOnceTheFeatureIsGone() async throws {
        var feature: WorkspacesFeature? = WorkspacesFeature(defaults: UserDefaults(suiteName: "workspaces-tests-\(UUID().uuidString)")!)
        let tools = feature!.tools
        feature = nil
        #expect(try await tools[0].run([:]) == [])
        #expect(try await tools[1].run(["name": "x"]) == .null)
    }

    @Test func connectionTokenSourceReadsTheBearer() async throws {
        let token = try await ConnectionTokenSource(connection: try #require(FakeGCP().connection)).accessToken()
        #expect(token == FakeGCP.token)
        let unsigned = IntegrationConnection(baseURL: URL(string: "https://www.googleapis.com")!, headers: ["Authorization": "Basic abc"])
        await #expect(throws: ToolError("The Google Cloud integration didn't provide a token.")) {
            _ = try await ConnectionTokenSource(connection: unsigned).accessToken()
        }
    }
}

@MainActor
@Suite("Workspaces widget")
struct WorkspacesWidgetTests {
    @Test func declaration() {
        #expect(WorkspacesWidget.kind == "workspaces.list")
        #expect(WorkspacesWidget.sizeLimits == GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20))
        let type = WidgetType(WorkspacesWidget.self)
        #expect(type.defaultConfig == ["onlyMine": true])
        #expect(type.preview != nil)
        #expect(type.sizeLimits == WorkspacesWidget.sizeLimits)
    }

    @Test func snapshotFollowsOnlyMine() async throws {
        let (feature, host) = makeFeature(standardCluster())
        await feature.refresh()
        let context = WidgetContext(widgetID: UUID(), host: host)
        let mine = await WorkspacesWidget.snapshot(config: .init(onlyMine: true), context: context)
        #expect(mine.array?.compactMap { $0["name"]?.string } == ["checkout", "old-search", "papi-perf"])
        let all = await WorkspacesWidget.snapshot(config: .init(onlyMine: false), context: context)
        #expect(all.array?.count == 4)

        let empty = FakeHost([])
        #expect(await WorkspacesWidget.snapshot(config: .init(onlyMine: true), context: WidgetContext(widgetID: UUID(), host: empty)) == [])
    }

    @Test func rowItemsFromWorkspaces() async throws {
        let (feature, _) = makeFeature(standardCluster())
        await feature.refresh()
        let items = Dictionary(uniqueKeysWithValues: feature.workspaces.map { ($0.name, WorkspaceItem($0)) })
        let checkout = try #require(items["checkout"])
        #expect(checkout.cleanReason == nil && checkout.nodePool == .spot)
        #expect(checkout.subtitle.hasPrefix("sadik · feat/checkout · deployed "))
        #expect(items["old-search"]?.cleanReason == "not deployed for over a week")
        // Persisted: never flagged, though old and never deployed.
        #expect(items["papi-perf"]?.persist == true && items["papi-perf"]?.cleanReason == nil)
        #expect(items["papi-perf"]?.lastDeploy != nil)
    }

    @Test func previewSamplesStayOffline() {
        let samples = WorkspaceItem.samples
        #expect(samples.count == 4)
        #expect(samples.filter { $0.deployedBy == WorkspaceItem.sampleUser }.count == 3)
        #expect(samples.contains { $0.persist } && samples.contains { $0.cleanReason != nil })
        _ = WorkspacesWidget.preview(config: .init(onlyMine: true))
        _ = WorkspacesWidget.preview(config: .init(onlyMine: false))
    }
}

@Suite("Workspaces for a branch")
struct WorkspacesForBranchTests {
    @Test func branchNamesMatchLoosely() {
        #expect(WorkspacesFeature.sameBranch("feature/LAF-1-retries", "feature/LAF-1-retries"))
        #expect(WorkspacesFeature.sameBranch("refs/heads/Feature/LAF-1-retries", "origin/feature/laf-1-retries"))
        #expect(!WorkspacesFeature.sameBranch("main", "feature/LAF-1-retries"))
        #expect(!WorkspacesFeature.sameBranch(nil, "main"))
    }
}
