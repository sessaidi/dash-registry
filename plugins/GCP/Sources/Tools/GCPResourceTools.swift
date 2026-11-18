import DashKit
import Foundation

/// How the fetchers read Google Cloud resources, each trimmed to what's useful: GKE clusters,
/// Cloud Run, Pub/Sub (with backlog), Cloud SQL, Artifact Registry, Secret Manager (names only,
/// never values), IAM policy, Compute, Cloud Build, Error Reporting, uptime checks and audit logs.
/// None of them changes anything.
extension GCPIntegration {
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

    /// Subscriptions with their topic and delivery settings, and with `backlog` the messages waiting.
    func subscriptions(_ project: String, backlog withBacklog: Bool) async throws -> JSONValue {
        let subscriptions = try await fetchAll("https://pubsub.googleapis.com/v1/projects/\(project)/subscriptions", key: "subscriptions", ["pageSize": "500"])
        var backlog: [String: Double] = [:]
        var age: [String: Double] = [:]
        if withBacklog {
            backlog = try await latestPerSubscription(project, "pubsub.googleapis.com/subscription/num_undelivered_messages")
            age = try await latestPerSubscription(project, "pubsub.googleapis.com/subscription/oldest_unacked_message_age")
        }
        return Self.limited(.array(subscriptions.map { subscription in
            let name = Self.short(subscription["name"]).string ?? ""
            var item: JSONValue = ["name": .string(name), "topic": Self.short(subscription["topic"]),
                                   "ack_deadline": subscription["ackDeadlineSeconds"] ?? .null,
                                   "push": subscription["pushConfig"]?["pushEndpoint"] ?? .null,
                                   "dead_letter": Self.short(subscription["deadLetterPolicy"]?["deadLetterTopic"]),
                                   "filter": subscription["filter"] ?? .null]
            if withBacklog {
                item = item.merging(["undelivered": backlog[name].map(JSONValue.number) ?? .null,
                                     "oldest_unacked_seconds": age[name].map(JSONValue.number) ?? .null])
            }
            return item
        }))
    }

    /// Repositories of one location, or of every location the project has.
    func artifactRepositories(_ project: String, location: String?) async throws -> JSONValue {
        let base = "https://artifactregistry.googleapis.com/v1/projects/\(project)/locations"
        var locations = location.map { [$0] } ?? []
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
    }

    /// A repository's newest images, or with `package` that image's tags.
    func artifactImages(_ input: JSONValue) async throws -> JSONValue {
        let base = "https://artifactregistry.googleapis.com/v1/projects/\(input["project"]?.string ?? "")/locations/\(input["location"]?.string ?? "")/repositories/\(input["repository"]?.string ?? "")"
        if let package = input["package"]?.string {
            guard !package.contains(".."), !package.contains("?"), !package.contains("#") else { throw ToolError("“\(package)” isn't a valid package.") }
            let encoded = package.replacingOccurrences(of: "/", with: "%2F")
            let tags = try await fetchAll("\(base)/packages/\(encoded)/tags", key: "tags", ["pageSize": "200"], pages: 3)
            return Self.limited(.array(tags.map { ["tag": Self.short($0["name"]), "version": Self.short($0["version"])] }))
        }
        let images = try await fetchAll("\(base)/dockerImages", key: "dockerImages", ["pageSize": "50", "orderBy": "update_time desc"], pages: 1)
        return Self.limited(.array(images.map { image in
            ["uri": image["uri"] ?? .null, "tags": image["tags"] ?? .array([]), "uploaded": image["uploadTime"] ?? .null,
             "updated": image["updateTime"] ?? .null, "size_bytes": image["imageSizeBytes"] ?? .null]
        }))
    }

    /// VMs of every zone (one aggregated call).
    func computeInstances(_ project: String, filter: String?) async throws -> JSONValue {
        let result = try await fetch("https://compute.googleapis.com/compute/v1/projects/\(project)/aggregated/instances",
                                     ["filter": filter, "maxResults": "500", "returnPartialSuccess": "true"])
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
    }

    /// A build, trimmed: status, trigger, where it came from, when, and why it failed.
    nonisolated static func build(_ build: JSONValue) -> JSONValue {
        let substitutions = build["substitutions"]
        return ["id": build["id"] ?? .null, "status": build["status"] ?? .null, "trigger": build["buildTriggerId"] ?? .null,
                "repo": substitutions?["REPO_NAME"] ?? .null, "branch": substitutions?["BRANCH_NAME"] ?? .null,
                "commit": substitutions?["SHORT_SHA"] ?? substitutions?["COMMIT_SHA"] ?? .null,
                "started": build["startTime"] ?? build["createTime"] ?? .null, "finished": build["finishTime"] ?? .null,
                "failure": build["failureInfo"]?["detail"] ?? .null, "log": build["logUrl"] ?? .null]
    }

    /// An error group, trimmed: its representative message (1,500 characters at most), where, how often.
    nonisolated static func errorGroup(_ group: JSONValue) -> JSONValue {
        let event = group["representative"]
        var message = event?["message"]?.string ?? ""
        if message.count > 1_500 { message = String(message.prefix(1_500)) + "…" }
        return ["group": group["group"]?["groupId"] ?? .null, "message": .string(message),
                "service": event?["serviceContext"]?["service"] ?? .null, "version": event?["serviceContext"]?["version"] ?? .null,
                "count": group["count"] ?? .null, "users": group["affectedUsersCount"] ?? .null,
                "first_seen": group["firstSeenTime"] ?? .null, "last_seen": group["lastSeenTime"] ?? .null]
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
        let now = self.now()
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
