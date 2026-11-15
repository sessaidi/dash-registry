import DashKit
import Foundation
import WorkspaceKit

extension WorkspacesFeature {
    private struct CreateInput: Decodable { let name: String; let profile: String?; let services: [String]?; let worktree: String? }
    private struct NameInput: Decodable { let name: String }
    private struct DeployInput: Decodable { let name: String; let runTests: Bool? }
    private struct LogsInput: Decodable { let name: String; let pod: String; let container: String?; let previous: Bool?; let tail: Int?; let sinceSeconds: Int? }
    private struct CloudInput: Decodable { let name: String; let minSeverity: String?; let text: String?; let since: String?; let pod: String? }

    static func json(_ diagnosis: WorkspaceDiagnosis) -> JSONValue {
        [
            "findings": .array(diagnosis.findings.map {
                ["severity": .string($0.severity), "title": .string($0.title), "reference": .string($0.reference), "evidence": .string($0.evidence), "hint": .string($0.hint)]
            }),
            "pods": .array(diagnosis.pods.map { pod in
                ["name": .string(pod.name), "app": .string(pod.app), "phase": .string(pod.phase), "reason": .string(pod.reason), "message": .string(pod.message),
                 "node": .string(pod.node), "failing_conditions": .array(pod.failingConditions.map { .string($0) }),
                 "containers": .array(pod.containers.map { container in
                     ["name": .string(container.name), "image": .string(container.image), "ready": .bool(container.ready), "restarts": .number(Double(container.restarts)),
                      "state": .string(container.state), "requests": .object(container.requests.mapValues { .string($0) }),
                      "limits": .object(container.limits.mapValues { .string($0) }), "usage": .object(container.usage.mapValues { .string($0) }),
                      "last_termination": container.lastTermination.map { last in
                          ["reason": .string(last.reason), "exit_code": .number(Double(last.exitCode)),
                           "started_at": last.startedAt.map { .string($0.formatted(.iso8601)) } ?? .null,
                           "finished_at": last.finishedAt.map { .string($0.formatted(.iso8601)) } ?? .null, "message": .string(last.message)]
                      } ?? .null]
                 })]
            }),
            "events": .array(diagnosis.events.prefix(60).map { event in
                ["type": .string(event.type), "reason": .string(event.reason), "object": .string(event.object), "count": .number(Double(event.count)),
                 "last_seen": event.lastSeen.map { .string($0.formatted(.iso8601)) } ?? .null, "message": .string(event.message)]
            }),
            "nodes": .array(diagnosis.nodes.map { ["name": .string($0.name), "pressures": .array($0.pressures.map { .string($0) }), "allocatable": .object($0.allocatable.mapValues { .string($0) })] }),
        ]
    }

    var workspaceTools: [ClaudeTool] {
        [
            ClaudeTool(
                name: "workspace_profiles",
                description: "The workspace profiles (named sets of services, e.g. signup: capig, papi, services-signup, services-user) and the worktrees workspaces can be linked to."
            ) { [weak self] _ in
                guard let self else { return nil }
                let worktrees = await worktrees()
                return ["profiles": .array(profiles.map { ["name": .string($0.name), "services": .array($0.services.map { .string($0) })] }),
                        "worktrees": .array(worktrees.map { ["path": .string($0.path), "branch": .string($0.branch), "issue": .string($0.issue), "suggested_name": .string($0.suggestedName)] }),
                        "links": .object(links.mapValues { ["worktree": .string($0.worktree), "service": .string($0.service)] })]
            },
            ClaudeTool(
                name: "workspace_create",
                description: "Create a workspace (like up-toolbox generate + up): copies the profile's services from the default namespace, writes the configuration into the worktree, and creates everything. Optionally linked to a worktree for later deploys.",
                properties: ["name": JSONSchema.string("Workspace name, usually the ticket key lowercased."),
                             "profile": JSONSchema.string("Profile name (see workspace_profiles); default \"default\"."),
                             "services": JSONSchema.object("Instead of a profile: list of services or shortcuts (capig, papi, vapi…)."),
                             "worktree": JSONSchema.string("Worktree path to link (see workspace_profiles).")],
                required: ["name"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(CreateInput.self)
                let services = request.services ?? profiles.first { $0.name == (request.profile ?? "default") }?.services ?? WorkspaceProfile.defaults[0].services
                try await create(name: request.name, services: services, worktree: request.worktree)
                return ["url": .string("https://\(WorkspaceGenerator.host(name: request.name.lowercased(), env: env, region: region))")]
            },
            ClaudeTool(
                name: "workspace_deploy_worktree",
                description: "Build the linked worktree's service and deploy it to the workspace (like up-toolbox workspace run): go test, go build, docker build, push, patch, wait for the rollout.",
                properties: ["name": JSONSchema.string("Workspace name."), "runTests": JSONSchema.boolean("Run go test first (default true).")],
                required: ["name"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(DeployInput.self)
                return ["image": .string(try await deployWorktree(request.name, runTests: request.runTests ?? true))]
            },
            ClaudeTool(
                name: "workspace_config_changes",
                description: "What the local configuration files (in the worktree) would change in the workspace: objects to create or update and the fields that differ. Read-only.",
                properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"]
            ) { [weak self] input in
                guard let self else { return nil }
                let changes = try await pendingChanges(try input.toolInput(NameInput.self).name)
                return .array(changes.filter { $0.kind != .unchanged }.map { ["object": .string($0.id), "change": .string($0.kind.rawValue), "fields": .array($0.differences.map { .string($0) })] })
            },
            ClaudeTool(
                name: "workspace_apply_config",
                description: "Apply the local configuration files to the workspace and restart the deployments whose ConfigMaps changed.",
                properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let changes = try await applyConfig(try input.toolInput(NameInput.self).name)
                return .array(changes.map { .string("\($0.kind.rawValue) \($0.id)") })
            },
            ClaudeTool(
                name: "workspace_diagnose",
                description: "Everything that explains a workspace's health: pods, containers (state, last termination such as OOMKilled with exit code and times, restarts, requests/limits, current usage), failing conditions, warning events, node pressure, and rule-based findings each with a reference and the verbatim evidence. Read-only.",
                properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"]
            ) { [weak self] input in
                guard let self else { return nil }
                return Self.json(try await diagnose(try input.toolInput(NameInput.self).name))
            },
            ClaudeTool(
                name: "workspace_logs",
                description: "A container's logs in a workspace (with timestamps). previous=true reads the run before the last restart, where a crash's last lines are. Read-only.",
                properties: ["name": JSONSchema.string("Workspace name."), "pod": JSONSchema.string("Pod name (see workspace_diagnose)."),
                             "container": JSONSchema.string("Container name."), "previous": JSONSchema.boolean("The previous run's logs."),
                             "tail": JSONSchema.integer("Last N lines (default 300)."), "sinceSeconds": JSONSchema.integer("Only this many seconds back.")],
                required: ["name", "pod"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(LogsInput.self)
                let text = try await logs(request.name, pod: request.pod, container: request.container, previous: request.previous ?? false,
                                          tail: min(request.tail ?? 300, 3000), sinceSeconds: request.sinceSeconds)
                return .string(String(text.suffix(60_000)))
            },
            ClaudeTool(
                name: "workspace_cloud_logs",
                description: "A workspace's logs in Google Cloud Logging (also for pods that restarted or are gone), newest first, filtered by severity, text, pod and time. Read-only.",
                properties: ["name": JSONSchema.string("Workspace name."),
                             "minSeverity": JSONSchema.string("Lowest severity.", enum: ["DEFAULT", "INFO", "WARNING", "ERROR", "CRITICAL"]),
                             "text": JSONSchema.string("Text the entry must contain."), "since": JSONSchema.string("30m, 1h, 6h, 24h, 7d (default 6h)."),
                             "pod": JSONSchema.string("Pod name.")],
                required: ["name"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(CloudInput.self)
                return try await cloudLogs(request.name, minSeverity: request.minSeverity, text: request.text, since: request.since ?? "6h", pod: request.pod, limit: 200)
            },
            ClaudeTool(
                name: "workspace_commands",
                description: "What Dash did for a workspace, each with the exact command that does the same thing (same output) and the usual kubectl/gcloud/up-toolbox equivalent.",
                properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"]
            ) { [weak self] input in
                guard let self else { return nil }
                return .array(commands(for: try input.toolInput(NameInput.self).name).prefix(50).map { step in
                    ["at": .string(step.at.formatted(.iso8601)), "what": .string(step.title), "command": .string(step.command),
                     "familiar": step.familiar.map(JSONValue.string) ?? .null, "failed": .bool(step.failed)]
                })
            },
        ]
    }

    /// Finds why a workspace restarts or fails, from Kubernetes and Google Cloud, with references
    /// and the verbatim evidence.
    static let doctorInstructions = """
        Find why the workspace misbehaves (restarts, crash loops, evictions, pending pods, failing probes, slow or failing requests) and where it comes from.
        1. workspace_findings for the likely causes, then workspace_pods, workspace_containers (last termination reason and exit code, restarts, requests/limits, usage), workspace_events and workspace_nodes for the details; workspace_train for what was deployed just before.
        2. For each container that restarted: workspace_logs with previous=true (the last lines before the exit), and the current logs around the error.
        3. Google Cloud: workspace_cloud_logs (errors and warnings over the last hours, also for pods that are gone), and workspace_metrics for memory against its limit (memory, memory_limit), cpu_limit, restarts and ephemeral_storage over 6h, to see what built up before the failure. For evictions and OOM kills, gcp_logs_query with resource.type="k8s_node" and the node name.
        4. Decide the root cause: not enough memory (OOMKilled, memory at its limit), disk (ephemeral-storage eviction, DiskPressure), CPU throttling, scheduling (no room in the node pool), image, configuration or secret missing, failing probes, or an application error.
        Every finding must give: the reference (pod/container, event reason and time, log timestamp, metric and time) in `target`; and in `detail` the verbatim evidence: the exact log lines, event message or status fields, quoted as they are (keep timestamps), followed by what they show. Suggest the fix (e.g. raise the memory limit to X in the deployment's resources, or what the code does wrong) in `suggestion`.
        """

    static let explainTask = AITask(id: "explain_logs", title: "Explain logs",
                                    summary: "Explains a container's logs: what happened, the lines that show it, and what to do.",
                                    models: [.sonnet, .haiku, .opus], defaultModel: .sonnet, efforts: [.low, .medium], defaultEffort: .low)

    var aiTasks: [AITask] { [Self.explainTask] }

    var agents: [AgentDefinition] {
        [AgentDefinition(
            id: "doctor", name: "Workspace doctor", summary: "Finds why your workspaces restart or fail, from Kubernetes and Google Cloud, with references and the verbatim logs.",
            systemImage: "stethoscope", role: "Site reliability engineer", specialities: ["Kubernetes", "GKE", "Cloud Logging", "Go services"],
            instructions: Self.doctorInstructions,
            tools: ["workspaces_list", "workspace_deployments", "workspace_pods", "workspace_containers", "workspace_events", "workspace_findings",
                    "workspace_nodes", "workspace_metrics", "workspace_logs", "workspace_cloud_logs", "workspace_config", "workspace_env",
                    "workspace_train", "gcp_logs_query"],
            scope: "Only the user's workspaces in the configured environment and region; never the default namespace.",
            schedule: AgentSchedule(everyMinutes: 30, events: ["workspace.deployed", "workspace.configured"]),
            enabledByDefault: false,
            precheck: { [weak self] _ in
                // Only run when one of the user's workspaces has a problem; name it in the context.
                guard let self else { return .skip("Workspaces is unavailable.") }
                var troubled: [String] = []
                for workspace in self.workspaces where workspace.deployedBy == self.username {
                    guard let status = try? await self.client().status(workspace.name) else { continue }
                    let bad = status.pods.filter { $0.problem != nil || $0.restarts > 0 || !$0.ready }
                    if !bad.isEmpty {
                        troubled.append("\(workspace.name): " + bad.map { "\($0.name) \($0.problem ?? $0.phase), \($0.restarts) restarts" }.joined(separator: "; "))
                    }
                }
                return troubled.isEmpty ? .skip("All your workspaces are healthy.") : .run(context: "Workspaces with problems:\n" + troubled.joined(separator: "\n"))
            })]
    }

    var events: [EventDefinition] {
        [EventDefinition("workspace.created", "A workspace was created."),
         EventDefinition("workspace.deployed", "A worktree or image was deployed to a workspace."),
         EventDefinition("workspace.configured", "Local configuration was applied to a workspace."),
         EventDefinition("workspace.deleted", "A workspace was deleted."),
         EventDefinition("workspace.cleaned", "A workspace was deleted because its PR was merged.")]
    }
}
