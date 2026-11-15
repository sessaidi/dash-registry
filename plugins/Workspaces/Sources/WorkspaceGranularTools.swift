import DashKit
import Foundation
import WorkspaceKit

/// Small, single-purpose tools, so Claude asks for exactly what it needs (and each call shows
/// in the Commands tab as one kubectl or gcloud command).
extension WorkspacesFeature {
    private struct Name: Decodable { let name: String }
    private struct PodFilter: Decodable { let name: String; let pod: String?; let app: String? }
    private struct EventsInput: Decodable { let name: String; let warningsOnly: Bool?; let object: String? }
    private struct AppInput: Decodable { let name: String; let app: String }
    private struct ConfigInput: Decodable { let name: String; let configMap: String? }
    private struct EnvInput: Decodable { let name: String; let app: String; let set: [String: String]?; let remove: [String]? }
    private struct MetricInput: Decodable { let name: String; let metric: String; let pod: String?; let container: String?; let since: String? }
    private struct LinkInput: Decodable { let name: String; let worktree: String; let service: String? }
    private struct TrainInput: Decodable { let name: String?; let limit: Int? }

    var granularTools: [ClaudeTool] {
        let name = JSONSchema.string("Workspace name.")
        return [
            ClaudeTool(name: "workspace_deployments", description: "A workspace's deployments: ready/desired replicas and images. Read-only.",
                       properties: ["name": name], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let status = try await client().status(try input.toolInput(Name.self).name)
                return .array(status.deployments.map { ["name": .string($0.name), "ready": .number(Double($0.ready)), "desired": .number(Double($0.desired)),
                                                         "images": .array($0.images.map { .string($0) })] })
            },
            ClaudeTool(name: "workspace_pods", description: "A workspace's pods: app, phase, readiness, restarts, problem (CrashLoopBackOff…), pod-level reason (Evicted…) and node. Filter by app. Read-only.",
                       properties: ["name": name, "app": JSONSchema.string("Only this app's pods.")], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PodFilter.self)
                let diagnosis = try await client().diagnose(request.name)
                return .array(diagnosis.pods.filter { request.app == nil || $0.app == request.app }.map { pod in
                    ["name": .string(pod.name), "app": .string(pod.app), "phase": .string(pod.phase), "reason": .string(pod.reason),
                     "message": .string(pod.message), "node": .string(pod.node),
                     "ready": .bool(pod.containers.allSatisfy(\.ready)), "restarts": .number(Double(pod.containers.map(\.restarts).reduce(0, +))),
                     "failing_conditions": .array(pod.failingConditions.map { .string($0) })]
                })
            },
            ClaudeTool(name: "workspace_containers", description: "Containers of a workspace's pods: state, last termination (reason such as OOMKilled, exit code, start/end times, message), restarts, requests/limits and current usage. Filter by pod. Read-only.",
                       properties: ["name": name, "pod": JSONSchema.string("Only this pod.")], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PodFilter.self)
                let diagnosis = try await client().diagnose(request.name)
                let pods = diagnosis.pods.filter { request.pod == nil || $0.name == request.pod }
                return .array(pods.flatMap { pod in pod.containers.map { container in
                    ["pod": .string(pod.name), "container": .string(container.name), "image": .string(container.image), "state": .string(container.state),
                     "ready": .bool(container.ready), "restarts": .number(Double(container.restarts)),
                     "requests": .object(container.requests.mapValues { .string($0) }), "limits": .object(container.limits.mapValues { .string($0) }),
                     "usage": .object(container.usage.mapValues { .string($0) }),
                     "last_termination": container.lastTermination.map { last in
                         ["reason": .string(last.reason), "exit_code": .number(Double(last.exitCode)), "message": .string(last.message),
                          "started_at": last.startedAt.map { .string($0.formatted(.iso8601)) } ?? .null,
                          "finished_at": last.finishedAt.map { .string($0.formatted(.iso8601)) } ?? .null]
                     } ?? .null]
                } })
            },
            ClaudeTool(name: "workspace_events", description: "Kubernetes events in a workspace, newest first (scheduling, pulls, probes, kills, evictions). Filter to warnings or one object (e.g. Pod/api-7f9c). Read-only.",
                       properties: ["name": name, "warningsOnly": JSONSchema.boolean("Only Warning events (default true)."),
                                    "object": JSONSchema.string("Kind/name, e.g. Pod/api-7f9c.")], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(EventsInput.self)
                let events = try await client().events(request.name)
                return .array(events.filter { (!(request.warningsOnly ?? true) || $0.type == "Warning") && (request.object == nil || $0.object == request.object) }
                    .prefix(100).map { event in
                        ["type": .string(event.type), "reason": .string(event.reason), "object": .string(event.object), "count": .number(Double(event.count)),
                         "last_seen": event.lastSeen.map { .string($0.formatted(.iso8601)) } ?? .null, "message": .string(event.message)]
                    })
            },
            ClaudeTool(name: "workspace_findings", description: "Likely causes of a workspace's problems (OOMKilled, evictions for disk or memory, unschedulable pods, image pulls, missing config, failing probes, node pressure), each with its reference and verbatim evidence. Read-only.",
                       properties: ["name": name], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let diagnosis = try await client().diagnose(try input.toolInput(Name.self).name)
                return .array(diagnosis.findings.map { ["severity": .string($0.severity), "title": .string($0.title), "reference": .string($0.reference),
                                                        "evidence": .string($0.evidence), "hint": .string($0.hint)] })
            },
            ClaudeTool(name: "workspace_nodes", description: "The nodes a workspace's pods run on: pressure conditions (MemoryPressure, DiskPressure, PIDPressure, NotReady) and allocatable resources. Read-only.",
                       properties: ["name": name], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let diagnosis = try await client().diagnose(try input.toolInput(Name.self).name)
                return .array(diagnosis.nodes.map { ["name": .string($0.name), "pressures": .array($0.pressures.map { .string($0) }),
                                                     "allocatable": .object($0.allocatable.mapValues { .string($0) })] })
            },
            ClaudeTool(name: "workspace_metrics", description: "Cloud Monitoring time series for a workspace's containers: memory (bytes), memory_limit and cpu_limit (fraction of the limit), cpu (cores), restarts, ephemeral_storage. Read-only.",
                       properties: ["name": name, "metric": JSONSchema.string("What to read.", enum: ["memory", "memory_limit", "cpu", "cpu_limit", "restarts", "ephemeral_storage"]),
                                    "pod": JSONSchema.string("Pod name."), "container": JSONSchema.string("Container name."),
                                    "since": JSONSchema.string("1h, 6h, 24h, 7d (default 6h).")], required: ["name", "metric"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(MetricInput.self)
                guard let tool = host?.integration("gcp")?.tools.first(where: { $0.name == "gcp_metrics_query" }) else {
                    throw ToolError("Update the Google Cloud integration (it needs gcp_metrics_query).")
                }
                var query: [String: JSONValue] = ["project": .string(env.project), "metric": .string(request.metric), "namespace": .string(request.name),
                                                  "cluster": .string(clusterName), "since": .string(request.since ?? "6h")]
                if let pod = request.pod { query["pod"] = .string(pod) }
                if let container = request.container { query["container"] = .string(container) }
                let result = try await tool.run(.object(query)) ?? .null
                record(request.name, WorkspaceStep(at: .now, title: "Cloud Monitoring \(request.metric)", command: result["command"]?.string ?? "", familiar: nil,
                                                   output: "\(result["series"]?.array?.count ?? 0) series", failed: false))
                return result
            },
            ClaudeTool(name: "workspace_config", description: "A workspace's configuration: its ConfigMaps' names, or one ConfigMap's files. Read-only.",
                       properties: ["name": name, "configMap": JSONSchema.string("ConfigMap name; omit to list them.")], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ConfigInput.self)
                if let configMap = request.configMap {
                    return .object(try await client().configMap(workspace: request.name, name: configMap).mapValues { .string(String($0.prefix(20_000))) })
                }
                return .array(try await client().configMaps(workspace: request.name).map { .string($0) })
            },
            ClaudeTool(name: "workspace_env", description: "An app's environment variables in a workspace (secret values are shown as references, never revealed). Read-only.",
                       properties: ["name": name, "app": JSONSchema.string("Deployment/container name.")], required: ["name", "app"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(AppInput.self)
                return .object(try await client().environment(workspace: request.name, app: request.app).mapValues { .string($0) })
            },
            ClaudeTool(name: "workspace_set_env", description: "Set or remove environment variables on an app in a workspace (its pods restart with them).",
                       properties: ["name": name, "app": JSONSchema.string("Deployment/container name."),
                                    "set": JSONSchema.object("Variables to set: {\"NAME\": \"value\"}."),
                                    "remove": JSONSchema.object("Names to remove: [\"NAME\"].")],
                       required: ["name", "app"], requiresApproval: true, writesRemotely: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(EnvInput.self)
                let car = startDeployment(request.name, kind: "config", app: request.app, summary: "env " + (request.set ?? [:]).keys.sorted().joined(separator: ", "))
                do { try await client().setEnvironment(workspace: request.name, app: request.app, set: request.set ?? [:], remove: request.remove ?? []) }
                catch { finish(car, error: error); throw error }
                finish(car)
                return "updated"
            },
            ClaudeTool(name: "workspace_restart", description: "Restart an app in a workspace (new pods, same spec), like kubectl rollout restart.",
                       properties: ["name": name, "app": JSONSchema.string("Deployment name.")], required: ["name", "app"], requiresApproval: true, writesRemotely: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(AppInput.self)
                try await client().restart(workspace: request.name, app: request.app)
                host?.emit("workspace.restarted", from: self, title: "\(request.app) restarted in \(request.name)", importance: .info)
                return "restarted"
            },
            ClaudeTool(name: "workspace_link_worktree", description: "Link a workspace to a worktree (folder) so it can be deployed from it; service is the app folder in a monorepo (apps/<service>).",
                       properties: ["name": name, "worktree": JSONSchema.string("Worktree path."), "service": JSONSchema.string("Service folder path, optional.")],
                       required: ["name", "worktree"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(LinkInput.self)
                link(request.name, worktree: (request.worktree as NSString).expandingTildeInPath, service: request.service.map { ($0 as NSString).expandingTildeInPath })
                return ["worktree": .string(links[request.name]?.worktree ?? ""), "service": .string(links[request.name]?.service ?? "")]
            },
            ClaudeTool(name: "workspace_train", description: "Deployment history (the train): what was deployed to a workspace (or all), with app, version, branch, who, when, duration and result. Read-only.",
                       properties: ["name": JSONSchema.string("Workspace name; omit for all."), "limit": JSONSchema.integer("How many (default 20).")]) { [weak self] input in
                guard let self else { return [] }
                let request = try input.toolInput(TrainInput.self)
                return .array(train(workspace: request.name, limit: min(request.limit ?? 20, 100)).map { car in
                    ["workspace": .string(car.workspace), "kind": .string(car.kind), "app": .string(car.app), "tag": .string(car.tag), "commit": .string(car.commit),
                     "branch": .string(car.branch), "by": .string(car.by), "at": .string(car.startedAt.formatted(.iso8601)), "status": .string(car.status),
                     "seconds": car.duration.map { .number($0.rounded()) } ?? .null, "error": .string(car.error)]
                })
            },
        ]
    }
}
