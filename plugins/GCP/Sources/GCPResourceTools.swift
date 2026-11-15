import DashKit
import Foundation

/// Read-only tools for common Google Cloud resources, each trimmed to what's useful: GKE
/// clusters, Cloud Run, Pub/Sub (with backlog), Cloud SQL, Artifact Registry, Secret Manager
/// (names only, never values), IAM policy, Compute, Cloud Build, Error Reporting, uptime
/// checks and audit logs. None of them changes anything.
extension GCPIntegration {
    private struct ProjectInput: Decodable { let project: String; let location: String?; let filter: String? }
    private struct ClusterInput: Decodable { let project: String; let location: String; let name: String }
    private struct RevisionsInput: Decodable { let project: String; let region: String; let service: String }
    private struct SubscriptionsInput: Decodable { let project: String; let backlog: Bool? }
    private struct ImagesInput: Decodable { let project: String; let location: String; let repository: String; let package: String? }
    private struct ErrorsInput: Decodable { let project: String; let period: String?; let service: String? }
    private struct AuditInput: Decodable { let project: String; let since: String?; let principal: String?; let method: String?; let limit: Int? }

    /// GET a Google API URL with query parameters and parse the JSON.
    func fetch(_ address: String, _ query: [String: String?] = [:]) async throws -> JSONValue {
        let connection = try requireConnection()
        guard var components = URLComponents(string: address) else { throw ToolError("Bad URL \(address)") }
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = (components.queryItems ?? []) + items }
        guard let url = components.url, connection.allows(url) else { throw ToolError("Only https://*.googleapis.com URLs are allowed.") }
        let (data, _) = try await connection.send(URLRequest(url: url), service: "Google Cloud")
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    /// Every page of a list (up to `pages`), the items under `key`.
    func fetchAll(_ address: String, key: String, _ query: [String: String?] = [:], pages: Int = 10) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var token: String?
        for _ in 0..<pages {
            var parameters = query
            if let token { parameters["pageToken"] = token }
            let page = try await fetch(address, parameters)
            items += page[key]?.array ?? []
            token = page["nextPageToken"]?.string
            if token?.isEmpty ?? true { break }
        }
        return items
    }

    /// The last path component of a resource name ("projects/p/locations/l/services/api" → "api").
    nonisolated static func short(_ value: JSONValue?) -> JSONValue {
        guard let text = value?.string else { return value ?? .null }
        return .string(String(text.split(separator: "/").last ?? Substring(text)))
    }

    static func limited(_ value: JSONValue) -> JSONValue {
        let text = value.jsonString()
        return text.count > responseLimit ? .string(String(text.prefix(responseLimit)) + "\n[truncated]") : value
    }

    var resourceTools: [ClaudeTool] {
        let project = JSONSchema.string("GCP project id.")
        return [
            ClaudeTool(
                name: "gcp_gke_clusters",
                description: "GKE clusters: name, location, status, version, node count and node pools (machine type, autoscaling, version).",
                properties: ["project": project, "location": JSONSchema.string("Region or zone (default: all).")], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let clusters = try await fetch("https://container.googleapis.com/v1/projects/\(request.project)/locations/\(request.location ?? "-")/clusters")["clusters"]?.array ?? []
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
            ClaudeTool(
                name: "gcp_gke_cluster",
                description: "One GKE cluster in full (networking, add-ons, maintenance window, conditions).",
                properties: ["project": project, "location": JSONSchema.string("Region or zone."), "name": JSONSchema.string("Cluster name.")],
                required: ["project", "location", "name"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ClusterInput.self)
                return Self.limited(try await fetch("https://container.googleapis.com/v1/projects/\(request.project)/locations/\(request.location)/clusters/\(request.name)"))
            },
            ClaudeTool(
                name: "gcp_cloud_run_services",
                description: "Cloud Run services: URL, latest ready revision, image, ready state, last change and who made it.",
                properties: ["project": project, "location": JSONSchema.string("Region (default: all).")], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let services = try await fetchAll("https://run.googleapis.com/v2/projects/\(request.project)/locations/\(request.location ?? "-")/services", key: "services")
                return Self.limited(.array(services.map { service in
                    ["name": Self.short(service["name"]), "uri": service["uri"] ?? .null, "revision": Self.short(service["latestReadyRevision"]),
                     "image": service["template"]?["containers"]?[0]?["image"] ?? .null,
                     "ready": service["terminalCondition"]?["state"] ?? .null, "updated": service["updateTime"] ?? .null,
                     "by": service["lastModifier"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_cloud_run_revisions",
                description: "A Cloud Run service's revisions, newest first: image, created, ready state and scaling.",
                properties: ["project": project, "region": JSONSchema.string("Region."), "service": JSONSchema.string("Service name.")],
                required: ["project", "region", "service"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(RevisionsInput.self)
                let revisions = try await fetchAll("https://run.googleapis.com/v2/projects/\(request.project)/locations/\(request.region)/services/\(request.service)/revisions",
                                                   key: "revisions", pages: 2)
                return Self.limited(.array(revisions.map { revision in
                    ["name": Self.short(revision["name"]), "image": revision["containers"]?[0]?["image"] ?? .null,
                     "created": revision["createTime"] ?? .null, "scaling": revision["scaling"] ?? .null,
                     "ready": .array((revision["conditions"]?.array ?? []).filter { $0["type"] == "Ready" }.map { $0["state"] ?? .null })]
                }))
            },
            ClaudeTool(
                name: "gcp_pubsub_topics",
                description: "Pub/Sub topics of a project.",
                properties: ["project": project], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let topics = try await fetchAll("https://pubsub.googleapis.com/v1/projects/\(request.project)/topics", key: "topics", ["pageSize": "500"])
                return .array(topics.map { ["name": Self.short($0["name"]), "labels": $0["labels"] ?? .null] })
            },
            ClaudeTool(
                name: "gcp_pubsub_subscriptions",
                description: "Pub/Sub subscriptions: topic, ack deadline, push or pull, dead-letter topic, filter; with backlog=true also the messages waiting and the oldest unacked age (Cloud Monitoring, last 10 minutes).",
                properties: ["project": project, "backlog": JSONSchema.boolean("Add backlog size and oldest unacked age.")], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(SubscriptionsInput.self)
                let subscriptions = try await fetchAll("https://pubsub.googleapis.com/v1/projects/\(request.project)/subscriptions", key: "subscriptions", ["pageSize": "500"])
                var backlog: [String: Double] = [:]
                var age: [String: Double] = [:]
                if request.backlog == true {
                    backlog = try await latestPerSubscription(request.project, "pubsub.googleapis.com/subscription/num_undelivered_messages")
                    age = try await latestPerSubscription(request.project, "pubsub.googleapis.com/subscription/oldest_unacked_message_age")
                }
                return Self.limited(.array(subscriptions.map { subscription in
                    let name = Self.short(subscription["name"]).string ?? ""
                    var item: JSONValue = ["name": .string(name), "topic": Self.short(subscription["topic"]),
                                           "ack_deadline": subscription["ackDeadlineSeconds"] ?? .null,
                                           "push": subscription["pushConfig"]?["pushEndpoint"] ?? .null,
                                           "dead_letter": Self.short(subscription["deadLetterPolicy"]?["deadLetterTopic"]),
                                           "filter": subscription["filter"] ?? .null]
                    if request.backlog == true {
                        item = item.merging(["undelivered": backlog[name].map(JSONValue.number) ?? .null,
                                             "oldest_unacked_seconds": age[name].map(JSONValue.number) ?? .null])
                    }
                    return item
                }))
            },
            ClaudeTool(
                name: "gcp_sql_instances",
                description: "Cloud SQL instances: database version, state, region, tier, IP addresses, availability and backups.",
                properties: ["project": project], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let instances = try await fetch("https://sqladmin.googleapis.com/v1/projects/\(request.project)/instances")["items"]?.array ?? []
                return Self.limited(.array(instances.map { instance in
                    ["name": instance["name"] ?? .null, "version": instance["databaseVersion"] ?? .null, "state": instance["state"] ?? .null,
                     "region": instance["region"] ?? .null, "tier": instance["settings"]?["tier"] ?? .null,
                     "availability": instance["settings"]?["availabilityType"] ?? .null,
                     "backups": instance["settings"]?["backupConfiguration"]?["enabled"] ?? .null,
                     "ips": .array((instance["ipAddresses"]?.array ?? []).map { ["type": $0["type"] ?? .null, "ip": $0["ipAddress"] ?? .null] })]
                }))
            },
            ClaudeTool(
                name: "gcp_artifact_repositories",
                description: "Artifact Registry repositories: format (DOCKER, NPM…), location, size and cleanup policies. Without location, every location is checked.",
                properties: ["project": project, "location": JSONSchema.string("Location, e.g. us, europe-west1 (default: all).")], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let base = "https://artifactregistry.googleapis.com/v1/projects/\(request.project)/locations"
                var locations = request.location.map { [$0] } ?? []
                if locations.isEmpty {
                    locations = try await fetchAll(base, key: "locations").compactMap { $0["locationId"]?.string }
                }
                var repositories: [JSONValue] = []
                for location in locations.prefix(40) {
                    repositories += try await fetchAll("\(base)/\(location)/repositories", key: "repositories").map { repository in
                        ["name": Self.short(repository["name"]), "location": .string(location), "format": repository["format"] ?? .null,
                         "size_bytes": repository["sizeBytes"] ?? .null, "description": repository["description"] ?? .null,
                         "cleanup_policies": .bool(repository["cleanupPolicies"] != nil)]
                    }
                }
                return Self.limited(.array(repositories))
            },
            ClaudeTool(
                name: "gcp_artifact_images",
                description: "Docker images in an Artifact Registry repository, most recently updated first: URI, tags, upload time and size. With package, the tags of that image instead.",
                properties: ["project": project, "location": JSONSchema.string("Repository location."),
                             "repository": JSONSchema.string("Repository name."), "package": JSONSchema.string("Image (package) name, for its tags.")],
                required: ["project", "location", "repository"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ImagesInput.self)
                let base = "https://artifactregistry.googleapis.com/v1/projects/\(request.project)/locations/\(request.location)/repositories/\(request.repository)"
                if let package = request.package {
                    let encoded = package.replacingOccurrences(of: "/", with: "%2F")
                    let tags = try await fetchAll("\(base)/packages/\(encoded)/tags", key: "tags", ["pageSize": "200"], pages: 3)
                    return Self.limited(.array(tags.map { ["tag": Self.short($0["name"]), "version": Self.short($0["version"])] }))
                }
                let images = try await fetchAll("\(base)/dockerImages", key: "dockerImages", ["pageSize": "50", "orderBy": "update_time desc"], pages: 1)
                return Self.limited(.array(images.map { image in
                    ["uri": image["uri"] ?? .null, "tags": image["tags"] ?? .array([]), "uploaded": image["uploadTime"] ?? .null,
                     "updated": image["updateTime"] ?? .null, "size_bytes": image["imageSizeBytes"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_secrets",
                description: "Secret Manager secrets: names, labels, replication, rotation and creation time. Metadata only: secret values are never read.",
                properties: ["project": project], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let secrets = try await fetchAll("https://secretmanager.googleapis.com/v1/projects/\(request.project)/secrets", key: "secrets", ["pageSize": "250"])
                return Self.limited(.array(secrets.map { secret in
                    ["name": Self.short(secret["name"]), "labels": secret["labels"] ?? .null, "created": secret["createTime"] ?? .null,
                     "replication": .string(secret["replication"]?["automatic"] != nil ? "automatic" : "user-managed"),
                     "rotation": secret["rotation"] ?? .null, "expires": secret["expireTime"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_iam_policy",
                description: "Who has which role on a project: each role with its members (users, groups, service accounts) and conditions. Read-only (getIamPolicy).",
                properties: ["project": project], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let policy = try await iamPolicy(request.project)
                return Self.limited(.array((policy["bindings"]?.array ?? []).map { binding in
                    ["role": binding["role"] ?? .null, "members": binding["members"] ?? .array([]), "condition": binding["condition"]?["title"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_compute_instances",
                description: "Compute Engine VMs across zones: name, zone, status, machine type, internal and external IPs, labels.",
                properties: ["project": project, "filter": JSONSchema.string("Compute filter, e.g. status=RUNNING or labels.env=prod.")], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let result = try await fetch("https://compute.googleapis.com/compute/v1/projects/\(request.project)/aggregated/instances",
                                             ["filter": request.filter, "maxResults": "500", "returnPartialSuccess": "true"])
                var instances: [JSONValue] = []
                for (_, zone) in result["items"]?.object ?? [:] {
                    for instance in zone["instances"]?.array ?? [] {
                        let network = instance["networkInterfaces"]?[0]
                        instances.append(["name": instance["name"] ?? .null, "zone": Self.short(instance["zone"]), "status": instance["status"] ?? .null,
                                          "machine": Self.short(instance["machineType"]), "internal_ip": network?["networkIP"] ?? .null,
                                          "external_ip": network?["accessConfigs"]?[0]?["natIP"] ?? .null, "labels": instance["labels"] ?? .null])
                    }
                }
                return Self.limited(.array(instances))
            },
            ClaudeTool(
                name: "gcp_cloud_builds",
                description: "Recent Cloud Build builds, newest first: status, trigger, repo, branch, commit, start and finish, failure reason and log URL.",
                properties: ["project": project, "filter": JSONSchema.string("Build filter, e.g. status=\"FAILURE\" or substitutions.BRANCH_NAME=\"main\".")],
                required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let builds = try await fetch("https://cloudbuild.googleapis.com/v1/projects/\(request.project)/builds", ["pageSize": "25", "filter": request.filter])["builds"]?.array ?? []
                return Self.limited(.array(builds.map { build in
                    let substitutions = build["substitutions"]
                    return ["id": build["id"] ?? .null, "status": build["status"] ?? .null, "trigger": build["buildTriggerId"] ?? .null,
                            "repo": substitutions?["REPO_NAME"] ?? .null, "branch": substitutions?["BRANCH_NAME"] ?? .null,
                            "commit": substitutions?["SHORT_SHA"] ?? substitutions?["COMMIT_SHA"] ?? .null,
                            "started": build["startTime"] ?? build["createTime"] ?? .null, "finished": build["finishTime"] ?? .null,
                            "failure": build["failureInfo"]?["detail"] ?? .null, "log": build["logUrl"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_error_groups",
                description: "Error Reporting: the most frequent error groups in a period: message, service, version, count, affected users, first and last seen.",
                properties: ["project": project,
                             "period": JSONSchema.string("Time range.", enum: ["PERIOD_1_HOUR", "PERIOD_6_HOURS", "PERIOD_1_DAY", "PERIOD_1_WEEK", "PERIOD_30_DAYS"]),
                             "service": JSONSchema.string("Only this service.")],
                required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ErrorsInput.self)
                let groups = try await fetch("https://clouderrorreporting.googleapis.com/v1beta1/projects/\(request.project)/groupStats", [
                    "timeRange.period": request.period ?? "PERIOD_1_DAY", "order": "COUNT_DESC", "pageSize": "50",
                    "serviceFilter.service": request.service,
                ])["errorGroupStats"]?.array ?? []
                return Self.limited(.array(groups.map { group in
                    let event = group["representative"]
                    var message = event?["message"]?.string ?? ""
                    if message.count > 1_500 { message = String(message.prefix(1_500)) + "…" }
                    return ["group": group["group"]?["groupId"] ?? .null, "message": .string(message),
                            "service": event?["serviceContext"]?["service"] ?? .null, "version": event?["serviceContext"]?["version"] ?? .null,
                            "count": group["count"] ?? .null, "users": group["affectedUsersCount"] ?? .null,
                            "first_seen": group["firstSeenTime"] ?? .null, "last_seen": group["lastSeenTime"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_uptime_checks",
                description: "Cloud Monitoring uptime checks: name, target (host or resource), path, period and regions checked from.",
                properties: ["project": project], required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ProjectInput.self)
                let checks = try await fetchAll("https://monitoring.googleapis.com/v3/projects/\(request.project)/uptimeCheckConfigs", key: "uptimeCheckConfigs")
                return Self.limited(.array(checks.map { check in
                    ["name": check["displayName"] ?? .null, "target": check["monitoredResource"]?["labels"] ?? check["resourceGroup"] ?? .null,
                     "path": check["httpCheck"]?["path"] ?? .null, "period": check["period"] ?? .null, "regions": check["selectedRegions"] ?? .null]
                }))
            },
            ClaudeTool(
                name: "gcp_audit_logs",
                description: "Admin Activity audit logs (who changed what): newest first, optionally for one principal (email) or method (e.g. SetIamPolicy, google.container.v1.ClusterManager.UpdateCluster). Read-only.",
                properties: ["project": project, "since": JSONSchema.string("How far back: 1h, 24h, 7d (default 24h)."),
                             "principal": JSONSchema.string("Email of who made the change."), "method": JSONSchema.string("Text in the method name."),
                             "limit": JSONSchema.integer("Max entries (default 100).")],
                required: ["project"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(AuditInput.self)
                return try await queryLogs(LogsInput(
                    project: request.project, filter: Self.auditFilter(project: request.project, principal: request.principal, method: request.method),
                    namespace: nil, cluster: nil, pod: nil, container: nil, minSeverity: nil, text: nil,
                    since: request.since ?? "24h", until: nil, limit: request.limit ?? 100))
            },
        ]
    }

    nonisolated static func auditFilter(project: String, principal: String?, method: String?) -> String {
        var parts = [#"logName="projects/\#(project)/logs/cloudaudit.googleapis.com%2Factivity""#]
        if let principal, !principal.isEmpty { parts.append(#"protoPayload.authenticationInfo.principalEmail="\#(principal)""#) }
        if let method, !method.isEmpty { parts.append(#"protoPayload.methodName:"\#(method)""#) }
        return parts.joined(separator: " AND ")
    }

    /// `getIamPolicy` is a POST that only reads; it's sent to that one endpoint only.
    func iamPolicy(_ project: String) async throws -> JSONValue {
        let connection = try requireConnection()
        guard project.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects/\(project):getIamPolicy") else {
            throw ToolError("Bad project id \(project).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"options":{"requestedPolicyVersion":3}}"#.utf8)
        let (data, _) = try await connection.send(request, service: "Google Cloud")
        return try JSONValue.parse(data)
    }

    /// The newest value of a Pub/Sub subscription metric, per subscription id, over the last 10 minutes.
    func latestPerSubscription(_ project: String, _ metric: String) async throws -> [String: Double] {
        let now = Date.now
        let formatter = ISO8601DateFormatter()
        let result = try await fetch("https://monitoring.googleapis.com/v3/projects/\(project)/timeSeries", [
            "filter": #"metric.type="\#(metric)""#,
            "interval.startTime": formatter.string(from: now.addingTimeInterval(-600)), "interval.endTime": formatter.string(from: now),
            "aggregation.alignmentPeriod": "300s", "aggregation.perSeriesAligner": "ALIGN_MAX",
        ])
        var values: [String: Double] = [:]
        for series in result["timeSeries"]?.array ?? [] {
            guard let id = series["resource"]?["labels"]?["subscription_id"]?.string, let point = series["points"]?[0]?["value"] else { continue }
            values[id] = point["int64Value"]?.string.flatMap(Double.init) ?? point["int64Value"]?.double ?? point["doubleValue"]?.double ?? 0
        }
        return values
    }
}
