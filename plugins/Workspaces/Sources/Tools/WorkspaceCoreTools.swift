import DashKit
import Foundation
import WorkspaceKit

/// The core workspace tools (list, find by branch, status, clean candidates, persist, delete,
/// deploy an image), then the other tool sets.
extension WorkspacesFeature {
    private struct NameInput: Decodable { let name: String }
    private struct PersistInput: Decodable { let name: String; let persist: Bool }
    private struct DeployInput: Decodable { let name: String; let app: String; let image: String }
    private struct ListInput: Decodable { let mine: Bool? }

    static func json(_ workspace: Workspace) -> JSONValue {
        ["name": .string(workspace.name), "deployed_by": .string(workspace.deployedBy), "region": .string(workspace.region),
         "node_pool": .string(workspace.nodePool.rawValue), "persist": .bool(workspace.persist),
         "deployed_at": workspace.deployedAt.map { .string($0.formatted(.iso8601)) } ?? .null,
         "created_at": workspace.createdAt.map { .string($0.formatted(.iso8601)) } ?? .null,
         "git_branch": workspace.gitBranch.map(JSONValue.string) ?? .null, "url": .string("https://\(workspace.url)")]
    }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "workspaces_list",
                description: "List backend workspaces in the configured environment and region (namespace, owner, node pool, last deploy, persist flag, URL).",
                properties: ["mine": JSONSchema.boolean("Only workspaces deployed by the user.")]
            ) { [weak self] input in
                guard let self else { return [] }
                let mine = try input.toolInput(ListInput.self).mine ?? false
                let list = try await client().list()
                return .array(list.filter { !mine || $0.deployedBy == username }.map(Self.json))
            },
            DashiiTool(
                name: "workspaces_for_branch",
                description: "Workspaces deployed from a git branch, looked up in both dev and qa (name, environment, owner, last deploy, URL). Read-only.",
                properties: ["branch": JSONSchema.string("Branch name, e.g. feature/LAF-123-retries.")], required: ["branch"]
            ) { [weak self] input in
                guard let self else { return nil }
                guard let branch = input["branch"]?.string, !branch.isEmpty else { throw ToolError("Missing branch") }
                var found: [JSONValue] = []
                var errors: [String: JSONValue] = [:]
                for env in WorkspaceEnvironment.allCases {
                    do {
                        let list = try await client(for: env).list()
                        found += list.filter { Self.matches($0, branch: branch) }.map { Self.json($0).merging(["environment": .string(env.rawValue)]) }
                    } catch {
                        errors[env.rawValue] = .string(error.localizedDescription)
                    }
                }
                return ["branch": .string(branch), "workspaces": .array(found), "errors": .object(errors)]
            },
            DashiiTool(
                name: "workspace_status",
                description: "A workspace's deployments (ready/desired, images), pods (phase, restarts, problems like CrashLoopBackOff) and hostnames.",
                properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"]
            ) { [weak self] input in
                guard let self else { return nil }
                let status = try await client().status(try input.toolInput(NameInput.self).name)
                return Self.json(status.workspace).merging([
                    "deployments": .array(status.deployments.map { ["name": .string($0.name), "ready": .number(Double($0.ready)), "desired": .number(Double($0.desired)), "images": .array($0.images.map { .string($0) })] }),
                    "pods": .array(status.pods.map { ["name": .string($0.name), "app": .string($0.app), "phase": .string($0.phase), "ready": .bool($0.ready), "restarts": .number(Double($0.restarts)), "problem": $0.problem.map(JSONValue.string) ?? .null] }),
                    "hostnames": .array(status.hostnames.map { .string($0) }),
                ])
            },
            DashiiTool(
                name: "workspaces_clean_candidates",
                description: "Workspaces that `clean` would delete (not deployed for a week, created over a month ago without deploys, or on legacy/unknown node pools), excluding persisted ones. Read-only."
            ) { [weak self] _ in
                guard let self else { return [] }
                return .array(try await client().cleanCandidates().map { Self.json($0.workspace).merging(["reason": .string($0.reason)]) })
            },
            DashiiTool(
                name: "workspace_set_persist",
                description: "Mark a workspace as persisted (never cleaned) or not.",
                properties: ["name": JSONSchema.string("Workspace name."), "persist": JSONSchema.boolean("true to protect it from clean.")],
                required: ["name", "persist"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PersistInput.self)
                try await setPersist(request.name, request.persist)
                return "done"
            },
            DashiiTool(
                name: "workspace_delete",
                description: "Delete a workspace (its whole namespace). The user confirms in a dialog.",
                properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"], writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                try await delete(try input.toolInput(NameInput.self).name)
                return "deleted"
            },
            DashiiTool(
                name: "workspace_deploy_image",
                description: "Point a workspace app at an image already in Artifact Registry (strategic-merge patch, like `up-toolbox workspace run` after its build) and wait until every pod runs it.",
                properties: [
                    "name": JSONSchema.string("Workspace name."), "app": JSONSchema.string("Deployment/container name, e.g. common-api-gateway."),
                    "image": JSONSchema.string("Full image reference with tag."),
                ],
                required: ["name", "app", "image"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(DeployInput.self)
                try await deploy(request.name, app: request.app, image: request.image)
                return "deployed"
            },
        ] + workspaceTools + granularTools
    }
}
