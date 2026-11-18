import DashKit
import Foundation

/// Something Dash can fetch from Google Cloud and read back: the fetcher `gcp.<what>` calls the API
/// and stores the answer; the reader (same input, the old live tool's name) returns it with its
/// freshness, or says to fetch first.
struct GCPResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    var required: [String] = ["project"]
    /// Inputs that go into a URL path: checked so they can't leave their segment.
    var segments: [String] = ["project"]
    /// Answers to a query (logs, filters, raw URLs): kept a day, then dropped.
    var queryShaped = false
    /// How long a stored answer counts as fresh: logs and builds move fast, topics and repositories don't.
    var freshFor: Duration = .seconds(5 * 60)
    /// The reader's name when it isn't `gcp_<what>`.
    var reader: String?
    /// Calls Google Cloud and returns the answer that gets stored.
    let load: @MainActor (GCPIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "gcp." + what }
    var readerName: String { reader ?? "gcp_" + what }
    var kind: String { "gcp." + what }
}

extension GCPIntegration {
    /// Everything the Google Cloud tools used to ask Google live, now fetched into Dash and read there.
    var resources: [GCPResource] {
        let project = JSONSchema.string("GCP project id, e.g. acme-dev.")
        let hour: Duration = .seconds(3600)
        let quarter: Duration = .seconds(15 * 60)
        return [
            GCPResource(what: "projects", summary: "The Google Cloud projects the user can see: projectId, name and state.",
                        properties: [:], required: [], segments: [], freshFor: hour, reader: "gcp_list_projects") { gcp, _ in
                try await gcp.listProjects()
            },
            GCPResource(what: "logs", summary: "Cloud Logging entries, newest first: Kubernetes container logs of a namespace, pod or container, or any filter (e.g. k8s_pod events, k8s_node logs for OOM kills and disk pressure).",
                        properties: [
                            "project": project,
                            "filter": JSONSchema.string("Optional Cloud Logging filter, e.g. resource.type=\"k8s_node\" AND jsonPayload.MESSAGE:\"OOM\"."),
                            "namespace": JSONSchema.string("Kubernetes namespace."),
                            "cluster": JSONSchema.string("GKE cluster name."),
                            "pod": JSONSchema.string("Pod name."),
                            "container": JSONSchema.string("Container name."),
                            "minSeverity": JSONSchema.string("Lowest severity.", enum: ["DEFAULT", "DEBUG", "INFO", "NOTICE", "WARNING", "ERROR", "CRITICAL"]),
                            "text": JSONSchema.string("Text the entry must contain."),
                            "since": JSONSchema.string("How far back: 30m, 1h, 6h, 24h, 7d, or an ISO-8601 time (default 1h)."),
                            "until": JSONSchema.string("End: ISO-8601 or relative like since."),
                            "limit": JSONSchema.integer("Max entries, 1-1000 (default 200)."),
                        ],
                        queryShaped: true, reader: "gcp_logs_query") { gcp, input in
                Self.limited(try await gcp.queryLogs(input.toolInput(LogsInput.self)))
            },
            GCPResource(what: "metrics", summary: "Cloud Monitoring time series for Kubernetes containers: memory used (bytes) and memory/CPU limit utilization (0-1), CPU cores used, restarts per interval, ephemeral storage used. Points newest first, with max and last.",
                        properties: [
                            "project": project,
                            "metric": JSONSchema.string("Preset or a full metric type.", enum: ["memory", "memory_limit", "cpu", "cpu_limit", "restarts", "ephemeral_storage"]),
                            "namespace": JSONSchema.string("Kubernetes namespace."),
                            "pod": JSONSchema.string("Pod name."),
                            "container": JSONSchema.string("Container name."),
                            "cluster": JSONSchema.string("GKE cluster name."),
                            "since": JSONSchema.string("How far back: 1h, 6h, 24h, 7d (default 6h)."),
                            "step": JSONSchema.integer("Seconds per point (default 300)."),
                        ],
                        required: ["project", "metric"], queryShaped: true, reader: "gcp_metrics_query") { gcp, input in
                Self.limited(try await gcp.queryMetrics(input.toolInput(MetricsInput.self)))
            },
            GCPResource(what: "audit_logs", summary: "Admin Activity audit logs (who changed what), newest first, optionally for one principal (email) or method (e.g. SetIamPolicy, google.container.v1.ClusterManager.UpdateCluster).",
                        properties: ["project": project, "since": JSONSchema.string("How far back: 1h, 24h, 7d (default 24h)."),
                                     "principal": JSONSchema.string("Email of who made the change."), "method": JSONSchema.string("Text in the method name."),
                                     "limit": JSONSchema.integer("Max entries (default 100).")],
                        queryShaped: true) { gcp, input in
                let project = input["project"]?.string ?? ""
                return Self.limited(try await gcp.queryLogs(LogsInput(
                    project: project, filter: Self.auditFilter(project: project, principal: input["principal"]?.string, method: input["method"]?.string),
                    namespace: nil, cluster: nil, pod: nil, container: nil, minSeverity: nil, text: nil,
                    since: input["since"]?.string ?? "24h", until: nil, limit: input["limit"]?.int ?? 100)))
            },
            GCPResource(what: "gke_clusters", summary: "GKE clusters: name, location, status, version, node count and node pools (machine type, autoscaling, version).",
                        properties: ["project": project, "location": JSONSchema.string("Region or zone (default: all).")],
                        segments: ["project", "location"], freshFor: quarter) { gcp, input in
                let clusters = try await gcp.fetch("https://container.googleapis.com/v1/projects/\(input["project"]?.string ?? "")/locations/\(input["location"]?.string ?? "-")/clusters")["clusters"]?.array ?? []
                return Self.limited(.array(clusters.map { cluster in
                    ["name": cluster["name"] ?? .null, "location": cluster["location"] ?? .null, "status": cluster["status"] ?? .null,
                     "version": cluster["currentMasterVersion"] ?? .null, "nodes": cluster["currentNodeCount"] ?? .null,
                     "autopilot": cluster["autopilot"]?["enabled"] ?? .bool(false),
                     "node_pools": .array((cluster["nodePools"]?.array ?? []).map { pool in
                         ["name": pool["name"] ?? .null, "machine": pool["config"]?["machineType"] ?? .null, "version": pool["version"] ?? .null,
                          "autoscaling": pool["autoscaling"] ?? .null, "status": pool["status"] ?? .null]
                     })]
                }))
            },
            GCPResource(what: "gke_cluster", summary: "One GKE cluster in full (networking, add-ons, maintenance window, conditions).",
                        properties: ["project": project, "location": JSONSchema.string("Region or zone."), "name": JSONSchema.string("Cluster name.")],
                        required: ["project", "location", "name"], segments: ["project", "location", "name"], freshFor: quarter) { gcp, input in
                let path = "projects/\(input["project"]?.string ?? "")/locations/\(input["location"]?.string ?? "")/clusters/\(input["name"]?.string ?? "")"
                return Self.limited(try await gcp.fetch("https://container.googleapis.com/v1/" + path))
            },
            GCPResource(what: "cloud_run_services", summary: "Cloud Run services: URL, latest ready revision, image, ready state, last change and who made it.",
                        properties: ["project": project, "location": JSONSchema.string("Region (default: all).")], segments: ["project", "location"]) { gcp, input in
                let services = try await gcp.fetchAll("https://run.googleapis.com/v2/projects/\(input["project"]?.string ?? "")/locations/\(input["location"]?.string ?? "-")/services", key: "services")
                return Self.limited(.array(services.map { service in
                    ["name": Self.short(service["name"]), "uri": service["uri"] ?? .null, "revision": Self.short(service["latestReadyRevision"]),
                     "image": service["template"]?["containers"]?[0]?["image"] ?? .null,
                     "ready": service["terminalCondition"]?["state"] ?? .null, "updated": service["updateTime"] ?? .null,
                     "by": service["lastModifier"] ?? .null]
                }))
            },
            GCPResource(what: "cloud_run_revisions", summary: "A Cloud Run service's revisions, newest first: image, created, ready state and scaling.",
                        properties: ["project": project, "region": JSONSchema.string("Region."), "service": JSONSchema.string("Service name.")],
                        required: ["project", "region", "service"], segments: ["project", "region", "service"]) { gcp, input in
                let path = "projects/\(input["project"]?.string ?? "")/locations/\(input["region"]?.string ?? "")/services/\(input["service"]?.string ?? "")/revisions"
                let revisions = try await gcp.fetchAll("https://run.googleapis.com/v2/" + path, key: "revisions", pages: 2)
                return Self.limited(.array(revisions.map { revision in
                    ["name": Self.short(revision["name"]), "image": revision["containers"]?[0]?["image"] ?? .null,
                     "created": revision["createTime"] ?? .null, "scaling": revision["scaling"] ?? .null,
                     "ready": .array((revision["conditions"]?.array ?? []).filter { $0["type"] == "Ready" }.map { $0["state"] ?? .null })]
                }))
            },
            GCPResource(what: "pubsub_topics", summary: "Pub/Sub topics of a project.", properties: ["project": project], freshFor: hour) { gcp, input in
                let topics = try await gcp.fetchAll("https://pubsub.googleapis.com/v1/projects/\(input["project"]?.string ?? "")/topics", key: "topics", ["pageSize": "500"])
                return Self.limited(.array(topics.map { ["name": Self.short($0["name"]), "labels": $0["labels"] ?? .null] }))
            },
            GCPResource(what: "pubsub_subscriptions", summary: "Pub/Sub subscriptions: topic, ack deadline, push or pull, dead-letter topic, filter; with backlog=true also the messages waiting and the oldest unacked age (Cloud Monitoring, last 10 minutes).",
                        properties: ["project": project, "backlog": JSONSchema.boolean("Add backlog size and oldest unacked age.")]) { gcp, input in
                try await gcp.subscriptions(input["project"]?.string ?? "", backlog: input["backlog"]?.bool == true)
            },
            GCPResource(what: "sql_instances", summary: "Cloud SQL instances: database version, state, region, tier, IP addresses, availability and backups.",
                        properties: ["project": project], freshFor: quarter) { gcp, input in
                let instances = try await gcp.fetch("https://sqladmin.googleapis.com/v1/projects/\(input["project"]?.string ?? "")/instances")["items"]?.array ?? []
                return Self.limited(.array(instances.map { instance in
                    ["name": instance["name"] ?? .null, "version": instance["databaseVersion"] ?? .null, "state": instance["state"] ?? .null,
                     "region": instance["region"] ?? .null, "tier": instance["settings"]?["tier"] ?? .null,
                     "availability": instance["settings"]?["availabilityType"] ?? .null,
                     "backups": instance["settings"]?["backupConfiguration"]?["enabled"] ?? .null,
                     "ips": .array((instance["ipAddresses"]?.array ?? []).map { ["type": $0["type"] ?? .null, "ip": $0["ipAddress"] ?? .null] })]
                }))
            },
            GCPResource(what: "artifact_repositories", summary: "Artifact Registry repositories: format (DOCKER, NPM…), location, size and cleanup policies. Without location, every location is checked.",
                        properties: ["project": project, "location": JSONSchema.string("Location, e.g. us, europe-west1 (default: all).")],
                        segments: ["project", "location"], freshFor: hour) { gcp, input in
                try await gcp.artifactRepositories(input["project"]?.string ?? "", location: input["location"]?.string)
            },
            GCPResource(what: "artifact_images", summary: "Docker images in an Artifact Registry repository, most recently updated first: URI, tags, upload time and size. With package, the tags of that image instead.",
                        properties: ["project": project, "location": JSONSchema.string("Repository location."),
                                     "repository": JSONSchema.string("Repository name."), "package": JSONSchema.string("Image (package) name, for its tags.")],
                        required: ["project", "location", "repository"], segments: ["project", "location", "repository"], freshFor: quarter) { gcp, input in
                try await gcp.artifactImages(input)
            },
            GCPResource(what: "secrets", summary: "Secret Manager secrets: names, labels, replication, rotation and creation time. Metadata only: secret values are never read.",
                        properties: ["project": project], freshFor: hour) { gcp, input in
                let secrets = try await gcp.fetchAll("https://secretmanager.googleapis.com/v1/projects/\(input["project"]?.string ?? "")/secrets", key: "secrets", ["pageSize": "250"])
                return Self.limited(.array(secrets.map { secret in
                    ["name": Self.short(secret["name"]), "labels": secret["labels"] ?? .null, "created": secret["createTime"] ?? .null,
                     "replication": .string(secret["replication"]?["automatic"] != nil ? "automatic" : "user-managed"),
                     "rotation": secret["rotation"] ?? .null, "expires": secret["expireTime"] ?? .null]
                }))
            },
            GCPResource(what: "iam_policy", summary: "Who has which role on a project: each role with its members (users, groups, service accounts) and conditions (getIamPolicy, which only reads).",
                        properties: ["project": project], freshFor: quarter) { gcp, input in
                let policy = try await gcp.iamPolicy(input["project"]?.string ?? "")
                return Self.limited(.array((policy["bindings"]?.array ?? []).map { binding in
                    ["role": binding["role"] ?? .null, "members": binding["members"] ?? .array([]), "condition": binding["condition"]?["title"] ?? .null]
                }))
            },
            GCPResource(what: "compute_instances", summary: "Compute Engine VMs across zones: name, zone, status, machine type, internal and external IPs, labels.",
                        properties: ["project": project, "filter": JSONSchema.string("Compute filter, e.g. status=RUNNING or labels.env=prod.")],
                        queryShaped: true) { gcp, input in
                try await gcp.computeInstances(input["project"]?.string ?? "", filter: input["filter"]?.string)
            },
            GCPResource(what: "cloud_builds", summary: "Recent Cloud Build builds, newest first: status, trigger, repo, branch, commit, start and finish, failure reason and log URL.",
                        properties: ["project": project, "filter": JSONSchema.string("Build filter, e.g. status=\"FAILURE\" or substitutions.BRANCH_NAME=\"main\".")],
                        queryShaped: true) { gcp, input in
                let builds = try await gcp.fetch("https://cloudbuild.googleapis.com/v1/projects/\(input["project"]?.string ?? "")/builds",
                                                 ["pageSize": "25", "filter": input["filter"]?.string])["builds"]?.array ?? []
                return Self.limited(.array(builds.map(Self.build)))
            },
            GCPResource(what: "error_groups", summary: "Error Reporting: the most frequent error groups in a period: message, service, version, count, affected users, first and last seen.",
                        properties: ["project": project,
                                     "period": JSONSchema.string("Time range.", enum: ["PERIOD_1_HOUR", "PERIOD_6_HOURS", "PERIOD_1_DAY", "PERIOD_1_WEEK", "PERIOD_30_DAYS"]),
                                     "service": JSONSchema.string("Only this service.")],
                        queryShaped: true) { gcp, input in
                let groups = try await gcp.fetch("https://clouderrorreporting.googleapis.com/v1beta1/projects/\(input["project"]?.string ?? "")/groupStats", [
                    "timeRange.period": input["period"]?.string ?? "PERIOD_1_DAY", "order": "COUNT_DESC", "pageSize": "50",
                    "serviceFilter.service": input["service"]?.string,
                ])["errorGroupStats"]?.array ?? []
                return Self.limited(.array(groups.map(Self.errorGroup)))
            },
            GCPResource(what: "uptime_checks", summary: "Cloud Monitoring uptime checks: name, target (host or resource), path, period and regions checked from.",
                        properties: ["project": project], freshFor: hour) { gcp, input in
                let checks = try await gcp.fetchAll("https://monitoring.googleapis.com/v3/projects/\(input["project"]?.string ?? "")/uptimeCheckConfigs", key: "uptimeCheckConfigs")
                return Self.limited(.array(checks.map { check in
                    ["name": check["displayName"] ?? .null, "target": check["monitoredResource"]?["labels"] ?? check["resourceGroup"] ?? .null,
                     "path": check["httpCheck"]?["path"] ?? .null, "period": check["period"] ?? .null, "regions": check["selectedRegions"] ?? .null]
                }))
            },
            GCPResource(what: "api", summary: "Any Google Cloud REST URL on https://*.googleapis.com (GET only) when no other Google Cloud fetcher fits. Secret values are never read. The answer is stored cut to 200 KB.",
                        properties: ["url": JSONSchema.string("Full https URL on *.googleapis.com, e.g. https://container.googleapis.com/v1/projects/acme-dev/locations/-/clusters.")],
                        required: ["url"], segments: [], queryShaped: true, reader: "gcp_api_read") { gcp, input in
                try await gcp.apiGet(try Self.apiURL(input).absoluteString)
            },
        ]
    }

    /// The URL for `gcp.api`: https on `*.googleapis.com`, no `..`, never a secret's value.
    nonisolated static func apiURL(_ input: JSONValue) throws -> URL {
        let text = input["url"]?.string ?? ""
        guard let url = URL(string: text), url.scheme == "https", let host = url.host(), host.hasSuffix(".googleapis.com"), !text.contains("..") else {
            throw ToolError("Only https://*.googleapis.com URLs are allowed.")
        }
        if host.hasPrefix("secretmanager."), url.path().contains(":access") {
            throw ToolError("Secret values can't be read; gcp_secrets lists names and metadata.")
        }
        return url
    }

    /// A path segment from an input: a project id (letters, digits, `-.:`) or a location, name,
    /// region, service or repository (letters, digits, `-._`); never `.` or `..`.
    nonisolated static func checkSegment(_ name: String, _ value: String) throws {
        let extra: Set<Character> = name == "project" ? ["-", ".", ":"] : ["-", ".", "_"]
        guard value != ".", !value.contains(".."), value.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || extra.contains($0) }) else {
            throw ToolError("“\(value)” isn't a valid \(name).")
        }
    }
}
