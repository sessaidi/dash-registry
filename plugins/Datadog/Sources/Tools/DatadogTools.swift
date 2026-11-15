import DashKit
import Foundation

/// Claude's Datadog tools. All of them only read: GETs, plus the logs search (a POST that reads).
@MainActor
enum DatadogTools {
    private struct PathInput: Decodable { let path: String }
    private struct QueryInput: Decodable { let query: String? }
    private struct IDInput: Decodable { let id: String }
    private struct MetricsInput: Decodable { let query: String; let minutes: Int?; let from: Int?; let to: Int? }
    private struct LogsInput: Decodable { let query: String; let from: String?; let to: String?; let limit: Int? }
    private struct EventsInput: Decodable { let query: String?; let minutes: Int?; let limit: Int? }
    private struct SLOHistoryInput: Decodable { let id: String; let days: Int? }
    private struct HostsInput: Decodable { let filter: String?; let limit: Int? }

    static func tools(_ datadog: DatadogIntegration) -> [DashiiTool] {
        let query = JSONSchema.string("Datadog search query, e.g. status:alert service:api or tag:env:prod.")
        return [
            DashiiTool(
                name: "datadog_api_get",
                description: "GET any Datadog API path on the configured site (read-only), e.g. /api/v1/downtime?current_only=true. Only GET; only /api/ paths.",
                properties: ["path": JSONSchema.string("Path with query, starting with /api/, e.g. /api/v1/downtime?current_only=true.")],
                required: ["path"]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let path = try input.toolInput(PathInput.self).path
                guard path.hasPrefix("/api/"), !path.contains("://"), !path.contains("..") else {
                    throw ToolError("Give a path starting with /api/ (no full URLs).")
                }
                return DatadogIntegration.limited(try await datadog.requireConnection().get(path, service: "Datadog"))
            },
            DashiiTool(
                name: "datadog_monitors",
                description: "Search monitors with their status (OK, Alert, Warn, No Data), type, tags and when they last triggered. Default: every monitor not OK.",
                properties: ["query": JSONSchema.string("Monitor search, e.g. status:alert, tag:service:api, notification:@slack-oncall. Default: status:(alert OR warn OR \"no data\").")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let text = try input.toolInput(QueryInput.self).query ?? #"status:(alert OR warn OR "no data")"#
                return .array(DatadogMonitor.list(try await datadog.get("/api/v1/monitor/search", ["query": text, "per_page": "100"])).map(\.json))
            },
            DashiiTool(
                name: "datadog_monitor",
                description: "One monitor in detail: its query, message, thresholds, and the state of each group (which hosts or services are alerting).",
                properties: ["id": JSONSchema.string("Monitor id.")], required: ["id"]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let id = try input.toolInput(IDInput.self).id.filter(\.isNumber)
                return DatadogIntegration.limited(try await datadog.get("/api/v1/monitor/\(id)", ["group_states": "all"]))
            },
            DashiiTool(
                name: "datadog_metrics_query",
                description: "Query a metric timeseries, e.g. avg:system.cpu.user{service:api} by {host} or sum:trace.http.request.errors{env:prod}.as_count(). Returns series with points.",
                properties: ["query": JSONSchema.string("Metrics query."),
                             "minutes": JSONSchema.integer("Look back this many minutes (default 60)."),
                             "from": JSONSchema.integer("Start, Unix seconds (instead of minutes)."),
                             "to": JSONSchema.integer("End, Unix seconds (default now).")],
                required: ["query"]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let request = try input.toolInput(MetricsInput.self)
                let to = request.to ?? Int(Date().timeIntervalSince1970)
                let from = request.from ?? to - 60 * min(max(request.minutes ?? 60, 1), 60 * 24 * 30)
                return DatadogIntegration.limited(try await datadog.get("/api/v1/query", ["query": request.query, "from": String(from), "to": String(to)]))
            },
            DashiiTool(
                name: "datadog_logs_search",
                description: "Search logs (newest first): timestamp, service, status, host and message. Read-only.",
                properties: ["query": JSONSchema.string("Logs query, e.g. service:api status:error @http.status_code:500."),
                             "from": JSONSchema.string("Start, e.g. now-15m (default), now-2h or an ISO date."),
                             "to": JSONSchema.string("End (default now)."),
                             "limit": JSONSchema.integer("How many (default 50, at most 200).")],
                required: ["query"]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let request = try input.toolInput(LogsInput.self)
                let result = try await datadog.searchLogs(query: request.query, from: request.from ?? "now-15m", to: request.to ?? "now",
                                                          limit: min(max(request.limit ?? 50, 1), 200))
                return DatadogIntegration.limited(.array((result["data"]?.array ?? []).map(DatadogTools.log)))
            },
            DashiiTool(
                name: "datadog_events",
                description: "Events (deploys, alerts, config changes) in a time window, newest first.",
                properties: ["query": JSONSchema.string("Events query, e.g. source:kubernetes service:api."),
                             "minutes": JSONSchema.integer("Look back this many minutes (default 60)."),
                             "limit": JSONSchema.integer("How many (default 50, at most 100).")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let request = try input.toolInput(EventsInput.self)
                return DatadogIntegration.limited(try await datadog.get("/api/v2/events", [
                    "filter[query]": request.query, "filter[from]": "now-\(min(max(request.minutes ?? 60, 1), 60 * 24 * 30))m",
                    "filter[to]": "now", "page[limit]": String(min(max(request.limit ?? 50, 1), 100)), "sort": "-timestamp",
                ]))
            },
            DashiiTool(
                name: "datadog_incidents",
                description: "Incidents (read-only): title, severity, state, commander, created and resolved times. Default: active ones.",
                properties: ["query": JSONSchema.string("Incident search, e.g. state:active (default), severity:SEV-1, state:resolved.")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let text = try input.toolInput(QueryInput.self).query ?? "state:active"
                return DatadogIntegration.limited(try await datadog.get("/api/v2/incidents/search", ["query": text, "page[size]": "50"]))
            },
            DashiiTool(
                name: "datadog_dashboards",
                description: "Dashboards (id, title, url, author), optionally only those whose title contains a text.",
                properties: ["query": JSONSchema.string("Text in the title.")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let text = try input.toolInput(QueryInput.self).query?.lowercased()
                let all = try await datadog.get("/api/v1/dashboard")["dashboards"]?.array ?? []
                let matching = all.filter { text == nil || ($0["title"]?.string?.lowercased().contains(text!) ?? false) }
                return DatadogIntegration.limited(.array(matching.prefix(200).map { dashboard in
                    ["id": dashboard["id"] ?? .null, "title": dashboard["title"] ?? .null, "author": dashboard["author_handle"] ?? .null,
                     "url": .string(datadog.appURL.absoluteString + (dashboard["url"]?.string ?? ""))]
                }))
            },
            DashiiTool(
                name: "datadog_dashboard",
                description: "One dashboard: its widgets and their queries (to know which metrics matter for a service).",
                properties: ["id": JSONSchema.string("Dashboard id, e.g. abc-def-ghi.")], required: ["id"]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let id = try input.toolInput(IDInput.self).id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
                return DatadogIntegration.limited(try await datadog.get("/api/v1/dashboard/\(id)"))
            },
            DashiiTool(
                name: "datadog_slos",
                description: "Service level objectives: name, type, targets, tags, and the current status where Datadog reports it.",
                properties: ["query": JSONSchema.string("SLO search, e.g. service:api.")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let text = try input.toolInput(QueryInput.self).query
                return DatadogIntegration.limited(try await datadog.get("/api/v1/slo", ["query": text, "limit": "100"]))
            },
            DashiiTool(
                name: "datadog_slo_history",
                description: "An SLO's history over the last days: SLI value, error budget remaining, and per-group detail.",
                properties: ["id": JSONSchema.string("SLO id."), "days": JSONSchema.integer("Days back (default 7, at most 90).")],
                required: ["id"]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let request = try input.toolInput(SLOHistoryInput.self)
                let to = Int(Date().timeIntervalSince1970)
                let from = to - 86_400 * min(max(request.days ?? 7, 1), 90)
                let id = request.id.filter { $0.isLetter || $0.isNumber }
                return DatadogIntegration.limited(try await datadog.get("/api/v1/slo/\(id)/history", ["from_ts": String(from), "to_ts": String(to)]))
            },
            DashiiTool(
                name: "datadog_hosts",
                description: "Hosts reporting to Datadog: name, aliases, apps, tags, up and muted state.",
                properties: ["filter": JSONSchema.string("Host name, alias or tag filter, e.g. env:prod."),
                             "limit": JSONSchema.integer("How many (default 100, at most 1000).")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let request = try input.toolInput(HostsInput.self)
                let result = try await datadog.get("/api/v1/hosts", ["filter": request.filter, "count": String(min(max(request.limit ?? 100, 1), 1000))])
                return DatadogIntegration.limited(.array((result["host_list"]?.array ?? []).map { host in
                    ["name": host["host_name"] ?? host["name"] ?? .null, "aliases": host["aliases"] ?? .null, "apps": host["apps"] ?? .null,
                     "up": host["up"] ?? .null, "muted": host["is_muted"] ?? .null, "tags": host["tags_by_source"] ?? .null,
                     "last_reported": host["last_reported_time"] ?? .null]
                }))
            },
            DashiiTool(
                name: "datadog_services",
                description: "Services in the Datadog service catalog (APM): name, team, contacts, links, languages and tier.",
                properties: ["query": JSONSchema.string("Text in the service name.")]
            ) { [weak datadog] input in
                guard let datadog else { return nil }
                let text = try input.toolInput(QueryInput.self).query?.lowercased()
                let all = try await datadog.get("/api/v2/services/definitions", ["page[size]": "100", "schema_version": "v2.2"])["data"]?.array ?? []
                let services = all.compactMap { item -> JSONValue? in
                    let schema = item["attributes"]?["schema"]
                    let name = schema?["dd-service"]?.string ?? ""
                    guard text == nil || name.lowercased().contains(text!) else { return nil }
                    return ["service": .string(name), "team": schema?["team"] ?? .null, "tier": schema?["tier"] ?? .null,
                            "languages": schema?["languages"] ?? .null, "contacts": schema?["contacts"] ?? .null, "links": schema?["links"] ?? .null]
                }
                return DatadogIntegration.limited(.array(services))
            },
        ]
    }

    /// A log line, without the bulk of its attributes.
    static func log(_ item: JSONValue) -> JSONValue {
        let attributes = item["attributes"]
        var message = attributes?["message"]?.string ?? ""
        if message.count > 1_000 { message = String(message.prefix(1_000)) + "…" }
        return ["timestamp": attributes?["timestamp"] ?? .null, "service": attributes?["service"] ?? .null,
                "status": attributes?["status"] ?? .null, "host": attributes?["host"] ?? .null, "message": .string(message)]
    }
}
