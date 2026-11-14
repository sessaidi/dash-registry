import DashKit
import Foundation
import SwiftData
import WorkspaceKit

/// A workspace as Dash last saw it: where it is, who owns it, its health, what runs in it and
/// when it last changed. Kept after deletion (`deleted`) so the history stays readable.
@Model
final class WorkspaceRecord {
    @Attribute(.unique) var key: String
    var name: String
    var env: String
    var region: String
    var url: String
    /// healthy, degraded (some pods not ready or restarting), failing, unknown, deleted.
    var status: String
    var deployedBy: String
    var createdAt: Date?
    var deployedAt: Date?
    var persist: Bool
    var nodePool: String
    var branch: String
    var gitHash: String
    var repo: String
    var worktree: String
    /// What runs: "app=tag" per deployment.
    var version: String
    var lastChange: Date
    var lastChangeSummary: String
    var deleted: Bool

    init(name: String, env: String, region: String) {
        key = "\(env)/\(region)/\(name)"
        self.name = name
        self.env = env
        self.region = region
        url = ""
        status = "unknown"
        deployedBy = ""
        persist = false
        nodePool = ""
        branch = ""
        gitHash = ""
        repo = ""
        worktree = ""
        version = ""
        lastChange = .now
        lastChangeSummary = ""
        deleted = false
    }

    static func key(_ name: String, env: WorkspaceEnvironment, region: WorkspaceRegion) -> String { "\(env.rawValue)/\(region.rawValue)/\(name)" }
}

/// One car of the deployment train: something shipped to a workspace (a worktree build, an
/// image, a configuration change, a creation), with its version, who, when and how it went.
@Model
final class WorkspaceDeployment {
    @Attribute(.unique) var id: UUID
    var workspace: String
    var env: String
    var region: String
    /// worktree, image, config, create.
    var kind: String
    var app: String
    var image: String
    var tag: String
    var branch: String
    var commit: String
    var repo: String
    var by: String
    var startedAt: Date
    var finishedAt: Date?
    /// running, succeeded, failed.
    var status: String
    var error: String
    var summary: String

    init(workspace: String, env: String, region: String, kind: String, app: String = "", image: String = "", by: String) {
        id = UUID()
        self.workspace = workspace
        self.env = env
        self.region = region
        self.kind = kind
        self.app = app
        self.image = image
        tag = image.split(separator: ":").last.map(String.init) ?? ""
        branch = ""
        commit = ""
        repo = ""
        self.by = by
        startedAt = .now
        status = "running"
        error = ""
        summary = ""
    }

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

extension WorkspacesFeature {
    // MARK: Records

    func record(for name: String) -> WorkspaceRecord? {
        let key = WorkspaceRecord.key(name, env: env, region: region)
        return try? host?.context.fetch(FetchDescriptor<WorkspaceRecord>(predicate: #Predicate { $0.key == key })).first
    }

    /// Updates the records from a fresh list (and marks the ones that disappeared as deleted).
    func store(_ list: [Workspace], health: [String: String] = [:]) {
        guard let context = host?.context else { return }
        let envName = env.rawValue
        let regionName = region.rawValue
        let existing = (try? context.fetch(FetchDescriptor<WorkspaceRecord>(predicate: #Predicate { $0.env == envName && $0.region == regionName }))) ?? []
        var byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for workspace in list {
            let record = byName[workspace.name] ?? {
                let record = WorkspaceRecord(name: workspace.name, env: envName, region: regionName)
                context.insert(record)
                record.lastChangeSummary = "Seen for the first time"
                return record
            }()
            byName[workspace.name] = nil
            func set<T: Equatable>(_ path: ReferenceWritableKeyPath<WorkspaceRecord, T>, _ value: T, change: String? = nil) {
                guard record[keyPath: path] != value else { return }
                record[keyPath: path] = value
                if let change { record.lastChange = .now; record.lastChangeSummary = change }
            }
            set(\.url, "https://\(workspace.url)")
            set(\.deployedBy, workspace.deployedBy)
            set(\.createdAt, workspace.createdAt)
            set(\.deployedAt, workspace.deployedAt, change: "Deployed")
            set(\.persist, workspace.persist, change: workspace.persist ? "Persisted" : "No longer persisted")
            set(\.nodePool, workspace.nodePool.rawValue)
            set(\.branch, workspace.gitBranch ?? "", change: "Branch \(workspace.gitBranch ?? "")")
            set(\.gitHash, workspace.gitHash ?? "")
            set(\.repo, workspace.repo ?? record.repo)
            set(\.worktree, links[workspace.name]?.worktree ?? record.worktree)
            if let state = health[workspace.name] { set(\.status, state, change: "Now \(state)") }
            set(\.deleted, false)
        }
        for record in byName.values where !record.deleted {
            record.deleted = true
            record.status = "deleted"
            record.lastChange = .now
            record.lastChangeSummary = "Deleted"
        }
        try? context.save()
    }

    /// healthy / degraded / failing, and what runs ("app=tag"), from a status.
    static func health(_ status: WorkspaceStatus) -> (state: String, version: String) {
        let failing = status.pods.contains { $0.problem != nil } || status.deployments.contains { $0.ready == 0 && $0.desired > 0 }
        let degraded = status.pods.contains { !$0.ready || $0.restarts > 0 } || status.deployments.contains { $0.ready < $0.desired }
        let version = status.deployments.map { "\($0.name)=\($0.images.first?.split(separator: ":").last.map(String.init) ?? "")" }.joined(separator: " ")
        return (failing ? "failing" : degraded ? "degraded" : "healthy", version)
    }

    /// Reads the status of the user's workspaces and stores their health and versions.
    func refreshHealth() async {
        guard let client = try? await client() else { return }
        var health: [String: String] = [:]
        for workspace in workspaces where workspace.deployedBy == username {
            guard let status = try? await client.status(workspace.name) else { continue }
            let (state, version) = Self.health(status)
            health[workspace.name] = state
            if let record = record(for: workspace.name), record.version != version {
                record.version = version
                record.lastChange = .now
                record.lastChangeSummary = "Now running \(version)"
            }
        }
        store(workspaces, health: health)
    }

    // MARK: The train

    /// Starts a car; finish it with `finish(_:error:)`.
    @discardableResult
    func startDeployment(_ workspace: String, kind: String, app: String = "", image: String = "", summary: String = "") -> WorkspaceDeployment? {
        guard let context = host?.context else { return nil }
        let deployment = WorkspaceDeployment(workspace: workspace, env: env.rawValue, region: region.rawValue, kind: kind, app: app, image: image, by: username)
        deployment.summary = summary
        if let link = links[workspace] {
            let folder = URL(fileURLWithPath: link.service)
            deployment.branch = (try? Shell.run("/usr/bin/git", ["rev-parse", "--abbrev-ref", "HEAD"], in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            deployment.commit = (try? Shell.run("/usr/bin/git", ["rev-parse", "--short", "HEAD"], in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            deployment.repo = (try? Shell.run("/usr/bin/git", ["config", "--get", "remote.origin.url"], in: folder)).flatMap(WorktreeBuild.slug) ?? ""
            if deployment.app.isEmpty, kind == "worktree" { deployment.app = WorktreeBuild.appName(folder) }
        }
        context.insert(deployment)
        try? context.save()
        return deployment
    }

    func finish(_ deployment: WorkspaceDeployment?, image: String? = nil, error: Error? = nil) {
        guard let deployment else { return }
        deployment.finishedAt = .now
        deployment.status = error == nil ? "succeeded" : "failed"
        deployment.error = error.map { WorkspacesFeature.describe($0) } ?? ""
        if let image {
            deployment.image = image
            deployment.tag = image.split(separator: ":").last.map(String.init) ?? ""
        }
        if let record = record(for: deployment.workspace), error == nil {
            record.lastChange = .now
            record.lastChangeSummary = switch deployment.kind {
            case "worktree", "image": "Deployed \(deployment.app) \(deployment.commit.isEmpty ? deployment.tag : deployment.commit)"
            case "config": "Configuration applied"
            default: "Created"
            }
        }
        try? host?.context.save()
    }

    /// The train: deployments newest first, optionally one workspace's, optionally only the user's.
    func train(workspace: String? = nil, mine: Bool = false, limit: Int = 200) -> [WorkspaceDeployment] {
        var descriptor = FetchDescriptor<WorkspaceDeployment>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit * 2
        let all = (try? host?.context.fetch(descriptor)) ?? []
        return Array(all.filter { (workspace == nil || $0.workspace == workspace) && (!mine || $0.by == username) }.prefix(limit))
    }

    // MARK: Knowledge and activity

    var knowledge: [KnowledgeEntity] {
        guard let context = host?.context else { return [] }
        return ((try? context.fetch(FetchDescriptor<WorkspaceRecord>())) ?? []).filter { !$0.deleted }.map { record in
            var links: [KnowledgeLink] = []
            if !record.repo.isEmpty { links.append(KnowledgeLink(to: "repo:\(record.repo)", kind: "deploys")) }
            if !record.deployedBy.isEmpty { links.append(KnowledgeLink(to: "person:\(record.deployedBy)", kind: "owned_by")) }
            return KnowledgeEntity(id: "workspace:\(record.key)", kind: "workspace", title: "Workspace \(record.name) (\(record.env)/\(record.region))",
                                   text: "Status \(record.status). Branch \(record.branch) \(record.gitHash). Runs \(record.version). Last change: \(record.lastChangeSummary).",
                                   url: URL(string: record.url), updated: record.lastChange, links: links)
        }
    }

    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "deploys", title: "Workspace deploys", unit: "deploys", systemImage: "shippingbox") { [weak self] interval in
            let deployments = (try? self?.host?.context.fetch(FetchDescriptor<WorkspaceDeployment>())) ?? []
            return ActivitySeries.countPerDay(deployments.map(\.startedAt), in: interval)
        }]
    }
}
