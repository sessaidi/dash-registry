import DashKit
import Foundation
import SwiftData

/// Workspaces for DashQL: the `workspaces` and `deploys` datasets, and the Workspaces and
/// Deployment Train widgets' query bars.
extension WorkspaceItem {
    static let queryFields: [QueryDataset.Field] = [
        .init("name", "string", "Workspace (namespace) name", aliases: ["workspace"]),
        .init("owner", "string", "Who deployed it", aliases: ["by", "deployed_by"]),
        .init("branch", "string", "Git branch deployed"),
        .init("tickets", "list", "Ticket keys in the branch (joins jira.key)"),
        .init("last_deploy", "date", "Last deploy (else creation)", aliases: ["deployed"]),
        .init("persist", "bool", "Never cleaned"),
        .init("node_pool", "string", "spot, standard or legacy", aliases: ["pool"]),
        .init("clean_reason", "string", "Why cleaning would delete it"),
        .init("cleanable", "bool", "Cleaning would delete it"),
    ]

    var queryRow: JSONValue {
        [
            "name": .string(name), "owner": .string(deployedBy), "branch": gitBranch.queryValue,
            "tickets": .array(WorkspaceItem.tickets(in: gitBranch ?? "").map(JSONValue.string)),
            "last_deploy": lastDeploy.queryValue, "persist": .bool(persist), "node_pool": .string("\(nodePool)"),
            "clean_reason": cleanReason.queryValue, "cleanable": .bool(cleanReason != nil),
        ]
    }

    static func tickets(in text: String) -> [String] {
        text.uppercased().matches(of: /[A-Z][A-Z0-9]{1,9}-\d+/).map { String($0.output) }
    }
}

extension TrainCar {
    static let queryFields: [QueryDataset.Field] = [
        .init("workspace", "string", "Workspace deployed to"),
        .init("kind", "string", "worktree, image or config"),
        .init("app", "string", "Deployment (service)"),
        .init("version", "string", "Commit or image tag"),
        .init("branch", "string", "Git branch"),
        .init("tickets", "list", "Ticket keys in the branch (joins jira.key)"),
        .init("by", "string", "Who deployed", aliases: ["owner"]),
        .init("at", "date", "When it started", aliases: ["started"]),
        .init("duration", "number", "Seconds it took"),
        .init("status", "string", "running, succeeded or failed"),
        .init("error", "string", "Why it failed"),
    ]

    var queryRow: JSONValue {
        [
            "workspace": .string(workspace), "kind": .string(kind), "app": .string(app), "version": .string(version),
            "branch": .string(branch), "tickets": .array(WorkspaceItem.tickets(in: branch).map(JSONValue.string)),
            "by": .string(by), "at": at.queryValue, "duration": duration.map { .number($0) } ?? .null,
            "status": .string(status), "error": error.isEmpty ? .null : .string(error),
        ]
    }

    init(_ deployment: WorkspaceDeployment) {
        self.init(id: deployment.id.uuidString, workspace: deployment.workspace, kind: deployment.kind, app: deployment.app,
                  version: deployment.commit.isEmpty ? deployment.tag : deployment.commit, branch: deployment.branch, by: deployment.by,
                  at: deployment.startedAt, duration: deployment.duration, status: deployment.status, error: deployment.error)
    }
}

extension WorkspacesFeature {
    var datasets: [QueryDataset] {
        [
            QueryDataset(name: "workspaces", aliases: ["ws"], summary: "Backend workspaces on GKE (the configured env and region), with owner, branch and last deploy.",
                         fields: WorkspaceItem.queryFields) { [weak self] _ in
                (self?.workspaces ?? []).map { WorkspaceItem($0).queryRow }
            },
            QueryDataset(name: "deploys", aliases: ["deployments", "train"], summary: "Deployments to workspaces (the train), newest first.", fields: TrainCar.queryFields) { [weak self] _ in
                guard let context = self?.host?.context else { return [] }
                return ((try? context.fetch(FetchDescriptor<WorkspaceDeployment>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? [])
                    .map { TrainCar($0).queryRow }
            },
        ]
    }
}
