import DashKit
import Foundation

/// Something Dash can fetch from Datadog and read back: the fetcher `datadog.<what>` calls the API
/// and stores the answer; the reader (same input, the old live tool's name) returns it with its
/// freshness, or says to fetch first.
struct DatadogResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    var required: [String] = []
    /// Answers to a query (searches, windows, raw paths): kept a day, then dropped.
    var queryShaped = false
    /// How long a stored answer counts as fresh: monitor states and logs move fast, dashboards don't.
    var freshFor: Duration = .seconds(5 * 60)
    /// The reader's name when it isn't `datadog_<what>`.
    var reader: String?
    /// Calls Datadog and returns the answer that gets stored.
    let load: @MainActor (DatadogIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "datadog." + what }
    var readerName: String { reader ?? "datadog_" + what }
    var kind: String { "datadog." + what }
}

extension DatadogIntegration {
    /// Everything the Datadog tools used to ask Datadog live, now fetched into Dash and read there.
    var resources: [DatadogResource] {
        let query = JSONSchema.string("Datadog search query, e.g. status:alert service:api or tag:env:prod.")
        let minute: Duration = .seconds(60)
        return [
            DatadogResource(what: "monitors", summary: "Monitors with their status (OK, Alert, Warn, No Data), type, tags and when they last triggered. Default: every monitor not OK.",
                            properties: ["query": JSONSchema.string("Monitor search, e.g. status:alert, tag:service:api, notification:@slack-oncall. Default: status:(alert OR warn OR \"no data\").")],
                            queryShaped: true, freshFor: minute) { datadog, input in
                let text = input["query"]?.string ?? #"status:(alert OR warn OR "no data")"#
                return .array(DatadogMonitor.list(try await datadog.get("/api/v1/monitor/search", ["query": text, "per_page": "100"])).map(\.json))
            },
            DatadogResource(what: "monitor", summary: "One monitor in detail: its query, message, thresholds, and the state of each group (which hosts or services are alerting).",
                            properties: ["id": JSONSchema.string("Monitor id.")], required: ["id"], freshFor: minute) { datadog, input in
                let id = (input["id"]?.string ?? input["id"]?.int.map(String.init) ?? "").filter(\.isNumber)
                guard !id.isEmpty else { throw ToolError("Give the monitor's numeric id.") }
                return Self.limited(try await datadog.get("/api/v1/monitor/\(id)", ["group_states": "all"]))
            },
            DatadogResource(what: "metrics", summary: "A metric timeseries, e.g. avg:system.cpu.user{service:api} by {host} or sum:trace.http.request.errors{env:prod}.as_count(): series with points.",
                            properties: ["query": JSONSchema.string("Metrics query."),
                                         "minutes": JSONSchema.integer("Look back this many minutes (default 60)."),
                                         "from": JSONSchema.integer("Start, Unix seconds (instead of minutes)."),
                                         "to": JSONSchema.integer("End, Unix seconds (default now).")],
                            required: ["query"], queryShaped: true, reader: "datadog_metrics_query") { datadog, input in
                let to = input["to"]?.int ?? Int(datadog.now().timeIntervalSince1970)
                let from = input["from"]?.int ?? to - 60 * min(max(input["minutes"]?.int ?? 60, 1), 60 * 24 * 30)
                return Self.limited(try await datadog.get("/api/v1/query", ["query": input["query"]?.string, "from": String(from), "to": String(to)]))
            },
            DatadogResource(what: "logs", summary: "Logs, newest first: timestamp, service, status, host and message.",
                            properties: ["query": JSONSchema.string("Logs query, e.g. service:api status:error @http.status_code:500."),
                                         "from": JSONSchema.string("Start, e.g. now-15m (default), now-2h or an ISO date."),
                                         "to": JSONSchema.string("End (default now)."),
                                         "limit": JSONSchema.integer("How many (default 50, at most 200).")],
                            required: ["query"], queryShaped: true, reader: "datadog_logs_search") { datadog, input in
                let result = try await datadog.searchLogs(query: input["query"]?.string ?? "", from: input["from"]?.string ?? "now-15m",
                                                          to: input["to"]?.string ?? "now", limit: min(max(input["limit"]?.int ?? 50, 1), 200))
                return Self.limited(.array((result["data"]?.array ?? []).map(Self.log)))
            },
            DatadogResource(what: "events", summary: "Events (deploys, alerts, config changes) in a time window, newest first.",
                            properties: ["query": JSONSchema.string("Events query, e.g. source:kubernetes service:api."),
                                         "minutes": JSONSchema.integer("Look back this many minutes (default 60)."),
                                         "limit": JSONSchema.integer("How many (default 50, at most 100).")],
                            queryShaped: true) { datadog, input in
                Self.limited(try await datadog.get("/api/v2/events", [
                    "filter[query]": input["query"]?.string, "filter[from]": "now-\(min(max(input["minutes"]?.int ?? 60, 1), 60 * 24 * 30))m",
                    "filter[to]": "now", "page[limit]": String(min(max(input["limit"]?.int ?? 50, 1), 100)), "sort": "-timestamp",
                ]))
            },
            DatadogResource(what: "incidents", summary: "Incidents: title, severity, state, commander, created and resolved times. Default: active ones.",
                            properties: ["query": JSONSchema.string("Incident search, e.g. state:active (default), severity:SEV-1, state:resolved.")],
                            queryShaped: true) { datadog, input in
                Self.limited(try await datadog.get("/api/v2/incidents/search", ["query": input["query"]?.string ?? "state:active", "page[size]": "50"]))
            },
            DatadogResource(what: "dashboards", summary: "Dashboards (id, title, url, author), optionally only those whose title contains a text.",
                            properties: ["query": JSONSchema.string("Text in the title.")], queryShaped: true, freshFor: .seconds(3600)) { datadog, input in
                let text = input["query"]?.string?.lowercased()
                let all = try await datadog.get("/api/v1/dashboard")["dashboards"]?.array ?? []
                let matching = all.filter { text == nil || ($0["title"]?.string?.lowercased().contains(text!) ?? false) }
                return Self.limited(.array(matching.prefix(200).map { dashboard in
                    ["id": dashboard["id"] ?? .null, "title": dashboard["title"] ?? .null, "author": dashboard["author_handle"] ?? .null,
                     "url": .string(datadog.appURL.absoluteString + (dashboard["url"]?.string ?? ""))]
                }))
            },
            DatadogResource(what: "dashboard", summary: "One dashboard: its widgets and their queries (to know which metrics matter for a service).",
                            properties: ["id": JSONSchema.string("Dashboard id, e.g. abc-def-ghi.")], required: ["id"], freshFor: .seconds(3600)) { datadog, input in
                let id = (input["id"]?.string ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" }
                guard !id.isEmpty else { throw ToolError("Give the dashboard id, e.g. abc-def-ghi.") }
                return Self.limited(try await datadog.get("/api/v1/dashboard/\(id)"))
            },
            DatadogResource(what: "slos", summary: "Service level objectives: name, type, targets, tags, and the current status where Datadog reports it.",
                            properties: ["query": JSONSchema.string("SLO search, e.g. service:api.")], queryShaped: true, freshFor: .seconds(15 * 60)) { datadog, input in
                Self.limited(try await datadog.get("/api/v1/slo", ["query": input["query"]?.string, "limit": "100"]))
            },
            DatadogResource(what: "slo_history", summary: "An SLO's history over the last days: SLI value, error budget remaining, and per-group detail.",
                            properties: ["id": JSONSchema.string("SLO id."), "days": JSONSchema.integer("Days back (default 7, at most 90).")],
                            required: ["id"], freshFor: .seconds(15 * 60)) { datadog, input in
                let to = Int(datadog.now().timeIntervalSince1970)
                let from = to - 86_400 * min(max(input["days"]?.int ?? 7, 1), 90)
                let id = (input["id"]?.string ?? "").filter { $0.isLetter || $0.isNumber }
                guard !id.isEmpty else { throw ToolError("Give the SLO id.") }
                return Self.limited(try await datadog.get("/api/v1/slo/\(id)/history", ["from_ts": String(from), "to_ts": String(to)]))
            },
            DatadogResource(what: "hosts", summary: "Hosts reporting to Datadog: name, aliases, apps, tags, up and muted state.",
                            properties: ["filter": JSONSchema.string("Host name, alias or tag filter, e.g. env:prod."),
                                         "limit": JSONSchema.integer("How many (default 100, at most 1000).")],
                            queryShaped: true, freshFor: .seconds(15 * 60)) { datadog, input in
                let result = try await datadog.get("/api/v1/hosts", ["filter": input["filter"]?.string, "count": String(min(max(input["limit"]?.int ?? 100, 1), 1000))])
                return Self.limited(.array((result["host_list"]?.array ?? []).map { host in
                    ["name": host["host_name"] ?? host["name"] ?? .null, "aliases": host["aliases"] ?? .null, "apps": host["apps"] ?? .null,
                     "up": host["up"] ?? .null, "muted": host["is_muted"] ?? .null, "tags": host["tags_by_source"] ?? .null,
                     "last_reported": host["last_reported_time"] ?? .null]
                }))
            },
            DatadogResource(what: "services", summary: "Services in the Datadog service catalog (APM): name, team, contacts, links, languages and tier.",
                            properties: ["query": JSONSchema.string("Text in the service name.")], queryShaped: true, freshFor: .seconds(3600)) { datadog, input in
                let text = input["query"]?.string?.lowercased()
                let all = try await datadog.get("/api/v2/services/definitions", ["page[size]": "100", "schema_version": "v2.2"])["data"]?.array ?? []
                return Self.limited(.array(all.compactMap { item -> JSONValue? in
                    let schema = item["attributes"]?["schema"]
                    let name = schema?["dd-service"]?.string ?? ""
                    guard text == nil || name.lowercased().contains(text!) else { return nil }
                    return ["service": .string(name), "team": schema?["team"] ?? .null, "tier": schema?["tier"] ?? .null,
                            "languages": schema?["languages"] ?? .null, "contacts": schema?["contacts"] ?? .null, "links": schema?["links"] ?? .null]
                }))
            },
            DatadogResource(what: "api", summary: "Any Datadog API path (GET only) when no other Datadog fetcher fits, e.g. /api/v1/downtime?current_only=true. The answer is stored cut to 200 KB.",
                            properties: ["path": JSONSchema.string("Path with query, starting with /api/, e.g. /api/v1/downtime?current_only=true.")],
                            required: ["path"], queryShaped: true, reader: "datadog_api_read") { datadog, input in
                try await datadog.requireConnection().get(try Self.apiPath(input), service: "Datadog")
            },
        ]
    }

    /// A raw path for `datadog.api`: only `/api/` paths on the configured site.
    nonisolated static func apiPath(_ input: JSONValue) throws -> String {
        let path = input["path"]?.string ?? ""
        guard path.hasPrefix("/api/"), !path.contains("://"), !path.contains("..") else {
            throw ToolError("Give a path starting with /api/ (no full URLs).")
        }
        return path
    }
}
