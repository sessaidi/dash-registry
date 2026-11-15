import DashKit
import Foundation
import Observation
import SwiftData
import SwiftUI
import WorkspaceKit

/// Layer 2 on Google Cloud: fubo backend workspaces, managed over the Kubernetes API
/// with WorkspaceKit (no up-toolbox, no kubectl).
@MainActor
@Observable
final class WorkspacesFeature: DashExtension {
    /// Finds and connects to the workspace cluster; tests swap in a stubbed client.
    typealias Connector = @Sendable (WorkspaceEnvironment, WorkspaceRegion, any GoogleTokenSource) async throws -> WorkspaceClient

    let id = "workspaces"
    let name = "Workspaces"
    let systemImage = "shippingbox"
    let metadata = ExtensionMetadata(
        version: "2.1.0", summary: "Backend workspaces on GKE linked to your worktrees: create, build, deploy, configure, logs and diagnosis, without up-toolbox or kubectl.", category: .cloud,
        homepage: "https://github.com/sessaidi/dash", minimumDashKit: "2.0.0")
    /// Google Cloud (credentials, Cloud Logging, Artifact Registry), Kubernetes (the kubeconfig
    /// contexts the replay commands use), Docker (image builds), GitHub (PR merges) and Agents
    /// (worktrees).
    let requires = ["gcp", "kubernetes", "docker", "github", "agents"]

    // Keys stay "workspaces.*" (the built-in feature's), so existing settings carry over.
    var env: WorkspaceEnvironment { didSet { defaults.set(env.rawValue, forKey: "workspaces.env"); reset() } }
    var region: WorkspaceRegion { didSet { defaults.set(region.rawValue, forKey: "workspaces.region"); reset() } }
    /// Matches the `deployed_by` label up-toolbox sets.
    var username: String { didSet { defaults.set(username, forKey: "workspaces.username") } }
    var pollMinutes: Int { didSet { defaults.set(pollMinutes, forKey: "workspaces.poll") } }
    /// Delete the user's workspace once the PR of the branch deployed to it is merged.
    var removeWhenMerged: Bool { didSet { defaults.set(removeWhenMerged, forKey: "workspaces.removeWhenMerged") } }
    /// What was done to each workspace, with the equivalent commands.
    var steps: [String: [WorkspaceStep]] = [:]
    /// Bumped when profiles or links change.
    var revision = 0

    private(set) var workspaces: [Workspace] = []
    private(set) var lastSync: Date?
    var lastError: String?
    private(set) var isLoading = false
    /// Workspace names with an operation (delete, deploy) in flight.
    var busy: Set<String> = []

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var connected: WorkspaceClient?
    /// Clients for the other environment, for lookups across dev and qa (the setting stays as it is).
    @ObservationIgnored private var others: [WorkspaceEnvironment: WorkspaceClient] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    var defaultsStore: UserDefaults { defaults }
    var connectedClient: WorkspaceClient? { connected }
    @ObservationIgnored private let connect: Connector

    init(defaults: UserDefaults = DashStorage.defaults, connect: @escaping Connector = { env, region, credentials in
        try await WorkspaceClient.connect(env: env, region: region, credentials: credentials)
    }) {
        self.defaults = defaults
        self.connect = connect
        env = defaults.string(forKey: "workspaces.env").flatMap(WorkspaceEnvironment.init) ?? .dev
        region = defaults.string(forKey: "workspaces.region").flatMap(WorkspaceRegion.init) ?? .us
        username = defaults.string(forKey: "workspaces.username") ?? NSUserName()
        pollMinutes = defaults.object(forKey: "workspaces.poll") as? Int ?? 2
        removeWhenMerged = defaults.object(forKey: "workspaces.removeWhenMerged") as? Bool ?? true
    }

    var widgets: [WidgetType] { [WidgetType(WorkspacesWidget.self), WidgetType(DeploymentTrainWidget.self)] }
    var models: [any PersistentModel.Type] { [WorkspaceRecord.self, WorkspaceDeployment.self] }
    func prepare(host: any ExtensionContext) async throws {
        await refresh()
        if let lastError { throw ToolError(lastError) }
    }

    func settingsView() -> AnyView { AnyView(WorkspacesSettings(feature: self)) }

    func start(host: any ExtensionContext) {
        self.host = host
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.refreshHealth()
                await self?.cleanUpMerged()
                try? await Task.sleep(for: .seconds(Double(max(self?.pollMinutes ?? 2, 1)) * 60))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    private func reset() {
        connected = nil
        workspaces = []
        Task { await refresh() }
    }

    /// The workspaces a list shows: all, or only the user's (`deployed_by` == `username`).
    func visible(onlyMine: Bool) -> [Workspace] {
        workspaces.filter { !onlyMine || $0.deployedBy == username }
    }

    /// Connects once per env/region: GKE discovery, then the external-dns probe.
    func client() async throws -> WorkspaceClient {
        if let connected, connected.env == env, connected.region == region { return connected }
        guard let connection = host?.integration("gcp")?.connection else { throw ToolError("Connect Google Cloud in Settings › Integrations.") }
        let client = try await connect(env, region, ConnectionTokenSource(connection: connection))
        connected = client
        return client
    }

    /// A client for `env` in the configured region, without changing the selected environment.
    func client(for env: WorkspaceEnvironment) async throws -> WorkspaceClient {
        if env == self.env { return try await client() }
        if let cached = others[env], cached.region == region { return cached }
        guard let connection = host?.integration("gcp")?.connection else { throw ToolError("Connect Google Cloud in Settings › Integrations.") }
        let client = try await connect(env, region, ConnectionTokenSource(connection: connection))
        others[env] = client
        return client
    }

    /// Workspaces in dev and qa deployed from `branch` (names compared without refs/heads/ and origin/).
    static func matches(_ workspace: Workspace, branch: String) -> Bool { sameBranch(workspace.gitBranch, branch) }

    nonisolated static func sameBranch(_ deployed: String?, _ branch: String) -> Bool {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "origin/", with: "").lowercased()
        }
        guard let deployed, !deployed.isEmpty else { return false }
        return clean(deployed) == clean(branch)
    }

    func refresh() async {
        guard host?.integration("gcp")?.isConnected == true, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            workspaces = try await client().list()
            store(workspaces)
            lastSync = .now
            lastError = nil
        } catch {
            connected = nil
            lastError = Self.describe(error)
        }
    }

    /// Private GKE endpoints are the usual failure: say so.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, [.timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(urlError.code) {
            return "Can't reach the cluster (\(urlError.code == .timedOut ? "timed out" : "connection failed")). Connect to the VPN if the GKE endpoint is private."
        }
        return error.localizedDescription
    }

    func setPersist(_ name: String, _ persist: Bool) async throws {
        try await client().setPersist(name, persist)
        await refresh()
    }

    /// Asks in the permission modal, then deletes and waits until the namespace is gone.
    func delete(_ name: String, confirm: Bool = true) async throws {
        if confirm {
            let allowed = await host?.permissions.ask(
                icon: "trash", title: "Delete workspace \(name)?",
                message: "Its namespace in \(env.rawValue)/\(region.rawValue) and everything in it will be deleted.",
                allowLabel: "Delete", denyLabel: "Cancel") ?? false
            guard allowed else { throw ToolError("The user cancelled.") }
        }
        busy.insert(name)
        defer { busy.remove(name) }
        try await client().delete(name)
        host?.emit("workspace.deleted", from: self, title: "Workspace \(name) deleted", importance: .notable)
        await refresh()
    }

    func deploy(_ name: String, app: String, image: String) async throws {
        busy.insert(name)
        defer { busy.remove(name) }
        let car = startDeployment(name, kind: "image", app: app, image: image)
        do { try await client().deploy(workspace: name, app: app, image: image) } catch { finish(car, error: error); throw error }
        finish(car)
        host?.emit("workspace.deployed", from: self, title: "\(app) deployed to \(name)", detail: image, importance: .notable)
        await refresh()
    }
}

/// Adapts the `gcp` integration's signing connection to WorkspaceKit's token source: the
/// connection adds a fresh Bearer header to a probe request and the token is read back from it.
struct ConnectionTokenSource: GoogleTokenSource {
    let connection: IntegrationConnection

    func accessToken() async throws -> String {
        let probe = try await connection.authorize(URLRequest(url: connection.baseURL))
        guard let header = probe.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else {
            throw ToolError("The Google Cloud integration didn't provide a token.")
        }
        return String(header.dropFirst("Bearer ".count))
    }
}
