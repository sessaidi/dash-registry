import DashKit
import Foundation

/// The SRE's tools: evidence gathered without a model, and narrow analysis handed to smaller ones.
@MainActor
enum SRETools {
    struct InvestigateInput: Decodable {
        let symptom: String
        let namespace: String?
        let service: String?
        let minutes: Int?
    }

    struct LogsInput: Decodable {
        let source: String
        let query: String?
        let project: String?
        let namespace: String?
        let pod: String?
        let minutes: Int?
    }

    struct NoteInput: Decodable {
        let title: String
        let markdown: String
    }

    static func tools(feature: SREFeature) -> [DashiiTool] {
        [
            DashiiTool(name: "sre_status", description: "What needs attention now: Datadog monitors not OK and Kubernetes pods not healthy, worst first, plus which sources are connected. No model call.") { [weak feature] _ in
                guard let feature else { return nil }
                return await Ops(host: try feature.requireHost()).signals().json
            },
            DashiiTool(name: "sre_investigate", description: "Investigate a symptom: gathers numbered evidence from what Dash has (alerting monitors, unhealthy pods, Kubernetes warning events, Datadog events, recent releases) and ranks likely causes with a smaller model (root_cause), each citing evidence ids and the next check. Missing or stale sources come back in gaps and refresh: data_fetch each refresh, then investigate again.",
                       properties: ["symptom": JSONSchema.string("What's wrong, e.g. \"5xx on api since 10:00\"."),
                                    "namespace": JSONSchema.string("Kubernetes namespace to look at."),
                                    "service": JSONSchema.string("Datadog service tag."),
                                    "minutes": JSONSchema.integer("How far back (default 60).")],
                       required: ["symptom"]) { [weak feature] input in
                guard let feature else { return nil }
                let host = try feature.requireHost()
                let request = try input.toolInput(InvestigateInput.self)
                let ops = Ops(host: host)
                let evidence = await ops.evidence(namespace: request.namespace, service: request.service, minutes: min(max(request.minutes ?? 60, 5), 24 * 60))
                let refresh: JSONValue = .array(evidence.refresh)
                guard !evidence.items.isEmpty else {
                    return ["evidence": [], "gaps": .array(evidence.gaps.map(JSONValue.string)), "refresh": refresh,
                            "analysis": .string(evidence.refresh.isEmpty ? "No evidence in the window: nothing alerting, no warning events or releases found."
                                                                         : "No evidence in Dash yet: data_fetch each refresh, then investigate again.")]
                }
                let analysis = try await DashiiFunctions.rootCause.run(.init(symptom: request.symptom, evidence: evidence.items), dashii: host.dashii,
                                                                      settings: host.aiSettings(.extension(feature.id), tasks: feature.aiTasks))
                return ["evidence": try JSONValue(encoding: evidence.items), "gaps": .array(evidence.gaps.map(JSONValue.string)), "refresh": refresh,
                        "analysis": try JSONValue(encoding: analysis)]
            },
            DashiiTool(name: "sre_logs", description: "Digest logs into recurring patterns with counts, severity and an example (a smaller model reads them): from datadog (a logs query), gcp (Cloud Logging: project, namespace, pod, text) or kubernetes (a pod), as Dash fetched them. When they aren't in Dash yet it says so with a refresh: data_fetch it, then call sre_logs again.",
                       properties: ["source": JSONSchema.string("Where the logs are.", enum: ["datadog", "gcp", "kubernetes"]),
                                    "query": JSONSchema.string("Datadog logs query, or text the lines must contain."),
                                    "project": JSONSchema.string("GCP project (gcp)."), "namespace": JSONSchema.string("Kubernetes namespace."),
                                    "pod": JSONSchema.string("Pod name (kubernetes, optional for gcp)."), "minutes": JSONSchema.integer("How far back (default 30).")],
                       required: ["source"]) { [weak feature] input in
                guard let feature else { return nil }
                let host = try feature.requireHost()
                let request = try input.toolInput(LogsInput.self)
                let minutes = min(max(request.minutes ?? 30, 1), 24 * 60)
                let (lines, reading) = try await Ops(host: host).logLines(source: request.source, query: request.query, project: request.project,
                                                                          namespace: request.namespace, pod: request.pod, minutes: minutes)
                guard reading.fetched else {
                    return ["lines": 0, "fetched": false, "refresh": reading.refresh ?? .null,
                            "summary": "These logs aren't in Dash yet: data_fetch the refresh, then call sre_logs again."]
                }
                let freshness: JSONValue = ["synced_at": reading.syncedAt.map(JSONValue.string) ?? .null, "stale": .bool(reading.stale),
                                            "refresh": reading.refresh ?? .null]
                guard !lines.isEmpty else { return JSONValue.object(["lines": 0, "summary": .string("No log lines in the last \(minutes) minutes.")]).merging(freshness) }
                let context = [request.source, request.namespace, request.pod, request.query].compactMap { $0 }.joined(separator: " ")
                let digest = try await DashiiFunctions.digestLogs.run(.init(lines: lines.map { String($0.prefix(400)) }, context: context),
                                                                     dashii: host.dashii, settings: host.aiSettings(.extension(feature.id), tasks: feature.aiTasks))
                var result = try JSONValue(encoding: digest)
                if case .object(var fields) = result { fields["lines"] = .number(Double(lines.count)); result = .object(fields) }
                return result.merging(freshness)
            },
            DashiiTool(name: "sre_incident_note", description: "Write an incident note in Notes › Incidents: timeline, impact, cause with evidence, mitigation, follow-ups (Markdown). Asks the user first.",
                       properties: ["title": JSONSchema.string("e.g. 2026-11-15 api 5xx after v1.42"), "markdown": JSONSchema.string("The note.")],
                       required: ["title", "markdown"], requiresApproval: true) { [weak feature] input in
                guard let feature else { return nil }
                let request = try input.toolInput(NoteInput.self)
                let url = try feature.requireHost().createNote(title: request.title, markdown: Sanitizer.clean(request.markdown), folder: "Incidents")
                return ["saved": .string(url.lastPathComponent)]
            },
        ]
    }
}
