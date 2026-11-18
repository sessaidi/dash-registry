import DashKit
import Foundation

/// Something Dash can fetch from GitLab and read back: the fetcher `gitlab.<what>` calls the API
/// and stores the answer; the reader (same input) returns it with its freshness, or says to fetch
/// first.
struct GitLabResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    var required: [String] = []
    /// Answers to a query (raw calls): kept a day, then dropped.
    var queryShaped = false
    var freshFor: Duration = .seconds(5 * 60)
    /// The reader's name when it isn't `gitlab_<what>`.
    var reader: String?
    /// Calls GitLab and returns the answer that gets stored.
    let load: @MainActor (GitLabIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "gitlab." + what }
    var readerName: String { reader ?? "gitlab_" + what }
    var kind: String { "gitlab." + what }
}

/// Fetch, then read: fetchers store GitLab's answers in Dash's mirror (`host.synced`), sanitized
/// and capped at 200 KB; the Dashii tools read them back with their freshness. Records are per
/// instance, kind `gitlab.<what>`, keyed by the normalized input's hash; the value keeps the
/// input next to the data. Tags and ranges keep the release mirror's shape (GitLabReleaseSync).
extension GitLabIntegration {
    /// Query-shaped answers older than this are dropped when their kind is stored again.
    static let queryRetention: TimeInterval = 86_400

    /// One scope per instance: gitlab.com and a self-managed instance never share records.
    var storeScope: String { "gitlab:" + (URL(string: instanceURL)?.host() ?? instanceURL) }

    var resources: [GitLabResource] {
        [
            GitLabResource(what: "merge_requests",
                           summary: "Open merge requests on a GitLab project (default: every watched project), or across the instance for the user with scope assigned_to_me / created_by_me.",
                           properties: [
                               "project": JSONSchema.string("Project path, e.g. group/service."),
                               "scope": JSONSchema.string("For instance-wide lists.", enum: ["assigned_to_me", "created_by_me", "all"]),
                           ]) { gitlab, input in
                try await gitlab.mergeRequests(project: input["project"]?.string, scope: input["scope"]?.string)
            },
            GitLabResource(what: "api",
                           summary: "Any GitLab REST v4 endpoint, read as the user (GET only), when no other GitLab fetcher fits, e.g. /projects/group%2Fservice/pipelines?per_page=5.",
                           properties: ["path": JSONSchema.string("Path and query after /api/v4, starting with /.")],
                           required: ["path"], queryShaped: true, reader: "gitlab_api_read") { gitlab, input in
                try await gitlab.get(try Self.validatedPath(input["path"]?.string ?? ""))
            },
        ]
    }

    func mergeRequests(project: String?, scope: String?) async throws -> JSONValue {
        var items: [JSONValue] = []
        if let scope, project == nil {
            items = try await get("/merge_requests?state=opened&scope=\(scope)&per_page=50").array ?? []
        } else {
            for project in project.map({ [$0] }) ?? projects {
                items += try await get("/projects/\(Self.projectID(project))/merge_requests?state=opened&per_page=50").array ?? []
            }
        }
        return .array(items.map {
            ["project": $0["references"]?["full"] ?? .null, "title": $0["title"] ?? .null, "author": $0["author"]?["username"] ?? .null,
             "draft": $0["draft"] ?? .null, "updated_at": $0["updated_at"] ?? .null, "url": $0["web_url"] ?? .null,
             "pipeline": $0["head_pipeline"]?["status"] ?? .null]
        })
    }

    /// A path for `gitlab.api`: relative to /api/v4, starting with one "/", with no scheme, host,
    /// "." or ".." segment or whitespace.
    nonisolated static func validatedPath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw ToolError("path must start with /") }
        let route = path.split(separator: "?", maxSplits: 1).first ?? ""
        guard !route.hasPrefix("//"), !route.contains("://") else { throw ToolError("path must be relative to /api/v4, not a full URL") }
        guard !path.contains(where: \.isWhitespace) else { throw ToolError("path must not contain spaces; percent-encode them") }
        guard !route.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw ToolError("path must not contain . or .. segments") }
        return path
    }

    var fetchers: [DataFetcher] {
        resources.map { resource in
            DataFetcher(name: resource.fetcherName, summary: resource.summary + " Read it with \(resource.readerName).",
                        properties: resource.properties, required: resource.required) { [weak self] input in
                guard let self else { return nil }
                return try await fetch(resource, input)
            }
        } + releaseFetchers
    }

    /// The readers Dashii and agents use.
    var readers: [DashiiTool] {
        resources.map { resource in
            DashiiTool(name: resource.readerName,
                       description: resource.summary + " Reads what Dash fetched (data_fetch \(resource.fetcherName)), with synced_at and stale.",
                       properties: resource.properties, required: resource.required) { [weak self] input in
                guard let self else { return nil }
                return try read(resource, input)
            }
        } + releaseReaders
    }

    /// The input as stored and hashed: only the schema's properties, strings trimmed, empty
    /// values dropped.
    nonisolated static func normalized(_ input: JSONValue, properties: [String: JSONValue]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (name, value) in input.object ?? [:] where properties[name] != nil {
            switch value {
            case .null: continue
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[name] = .string(trimmed) }
            default: result[name] = value
            }
        }
        return .object(result)
    }

    /// The input, normalized and checked: required fields, the project path, the raw call's path.
    nonisolated static func checkedInput(_ resource: GitLabResource, _ raw: JSONValue) throws -> JSONValue {
        let input = normalized(raw, properties: resource.properties)
        let missing = resource.required.filter { input[$0] == nil }
        if !missing.isEmpty { throw ToolError("Give \(missing.joined(separator: " and ")).") }
        if let project = input["project"]?.string { _ = try projectPath(project) }
        if let path = input["path"]?.string { _ = try validatedPath(path) }
        return input
    }

    /// Calls GitLab and stores the answer; returns the receipt.
    func fetch(_ resource: GitLabResource, _ raw: JSONValue) async throws -> JSONValue {
        guard let host else { throw ToolError("GitLab isn't started.") }
        let input = try Self.checkedInput(resource, raw)
        let scope = storeScope
        let data = Sanitizer.clean(try await resource.load(self, input)).capped()
        let key = input.queryKey
        let unchanged = host.synced.record(kind: resource.kind, scope: scope, key: key)?.value["data"] == data
        let syncedAt = now()
        host.synced.upsert([SyncedRecord(kind: resource.kind, scope: scope, key: key, value: ["input": input, "data": data], source: id, updatedAt: syncedAt)])
        if resource.queryShaped { expire(resource.kind, scope: scope, before: syncedAt.addingTimeInterval(-Self.queryRetention)) }
        return Self.receipt(stored: unchanged ? 0 : 1, unchanged: unchanged ? 1 : 0, keys: [resource.kind + "/" + key], syncedAt: syncedAt,
                            readWith: resource.readerName + " " + input.jsonString())
    }

    /// The stored answer with its freshness, or what to fetch.
    func read(_ resource: GitLabResource, _ raw: JSONValue) throws -> JSONValue {
        guard let host else { throw ToolError("GitLab isn't started.") }
        let input = try Self.checkedInput(resource, raw)
        guard let record = host.synced.record(kind: resource.kind, scope: storeScope, key: input.queryKey) else {
            return notFetched(resource.fetcherName, input: input)
        }
        let freshness = Freshness(syncedAt: record.updatedAt, maxAge: resource.freshFor,
                                  refresh: ["fetcher": .string(resource.fetcherName), "input": input], now: now())
        return Self.answer(record.value["data"] ?? .null, freshness)
    }

    /// `{stored, unchanged, keys, synced_at, read_with}`.
    nonisolated static func receipt(stored: Int, unchanged: Int, keys: [String], syncedAt: Date, readWith: String) -> JSONValue {
        ["stored": .number(Double(stored)), "unchanged": .number(Double(unchanged)), "keys": .array(keys.map(JSONValue.string)),
         "synced_at": .string(syncedAt.formatted(.iso8601)), "read_with": .string(readWith)]
    }

    /// Objects get the freshness fields; lists come as `items`, text as `text`.
    nonisolated static func answer(_ data: JSONValue, _ freshness: Freshness) -> JSONValue {
        switch data {
        case .object: data.merging(freshness.json)
        case .array: JSONValue.object(["items": data]).merging(freshness.json)
        default: JSONValue.object(["text": data]).merging(freshness.json)
        }
    }

    /// Drops this kind's records stored before `cutoff`.
    func expire(_ kind: String, scope: String, before cutoff: Date) {
        guard let host else { return }
        let records = host.synced.records(kind: kind, scope: scope)
        let kept = records.filter { $0.updatedAt >= cutoff }
        if kept.count < records.count { host.synced.replace(kind: kind, scope: scope, with: kept) }
    }
}
