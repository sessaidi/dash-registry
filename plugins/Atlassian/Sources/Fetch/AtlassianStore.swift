import DashKit
import Foundation

/// Fetch, then read: the fetchers store Jira's and Confluence's answers in Dash's mirror
/// (`host.synced`), sanitized and capped at 200 KB; the Dashii tools read them back with their
/// freshness. Records are per site, kind = the fetcher's name. One thing (a page, an issue, a
/// list) is keyed by its id and stored as is; a search is keyed by the normalized input's hash and
/// keeps the input next to the data.
extension AtlassianIntegration {
    /// Search answers older than this are dropped when their kind is stored again.
    static let queryRetention: TimeInterval = 86_400

    var maxAge: Duration { .seconds(cacheMinutes * 60) }

    var fetchers: [DataFetcher] {
        resources.map { resource in
            DataFetcher(name: resource.fetcher, summary: resource.summary + " Read it with \(resource.reader).",
                        properties: resource.properties, required: resource.required) { [weak self] input in
                guard let self else { throw ToolError("Atlassian isn't ready.") }
                return try await fetch(resource, input)
            }
        } + [docsFetcher]
    }

    /// The readers Dashii and agents use: same names and inputs as the old live tools.
    var readers: [DashiiTool] {
        resources.map { resource in
            DashiiTool(name: resource.reader,
                       description: resource.summary + " Reads what Dash fetched (data_fetch \(resource.fetcher)), with synced_at and stale.",
                       properties: resource.properties, required: resource.required) { [weak self] input in
                guard let self else { return nil }
                return try read(resource, input)
            }
        }
    }

    /// The input as stored and hashed: only the schema's properties, strings trimmed, empty values
    /// dropped, issue keys in upper case.
    nonisolated static func normalized(_ input: JSONValue, properties: [String: JSONValue]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (name, value) in input.object ?? [:] where properties[name] != nil {
            switch value {
            case .null: continue
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[name] = .string(name == "key" ? trimmed.uppercased() : trimmed) }
            default: result[name] = value
            }
        }
        return .object(result)
    }

    /// The input, normalized and checked (required fields, page id and issue key shapes).
    func checkedInput(_ resource: AtlassianResource, _ raw: JSONValue) throws -> JSONValue {
        let input = Self.normalized(raw, properties: resource.properties)
        let missing = resource.required.filter { input[$0] == nil }
        if !missing.isEmpty { throw ToolError("Give \(missing.joined(separator: " and ")).") }
        if let id = input["id"]?.string, !Self.validPageID(id) { throw ToolError("Page id should be letters and digits, like 123456.") }
        if let key = input["key"]?.string, !Self.validIssueKey(key) { throw ToolError("Issue key should look like KAN-1234.") }
        return input
    }

    /// Calls the site and stores the answer; returns the receipt.
    func fetch(_ resource: AtlassianResource, _ raw: JSONValue) async throws -> JSONValue {
        guard let mirror else { throw ToolError("Atlassian isn't started.") }
        let input = try checkedInput(resource, raw)
        let data = Sanitizer.clean(try await resource.load(self, input)).capped()
        let key = resource.key?(input) ?? input.queryKey
        let value: JSONValue = resource.key == nil ? ["input": input, "data": data] : data
        let unchanged = mirror.record(kind: resource.kind, scope: cacheScope, key: key)?.value == value
        let syncedAt = now()
        mirror.upsert([SyncedRecord(kind: resource.kind, scope: cacheScope, key: key, value: value, source: id, updatedAt: syncedAt)])
        if resource.key == nil { expire(resource.kind, before: syncedAt.addingTimeInterval(-Self.queryRetention)) }
        return Self.receipt(stored: unchanged ? 0 : 1, unchanged: unchanged ? 1 : 0, keys: [resource.kind + "/" + key], syncedAt: syncedAt,
                            readWith: resource.reader + " " + input.jsonString())
    }

    /// The stored answer with its freshness, or what to fetch.
    func read(_ resource: AtlassianResource, _ raw: JSONValue) throws -> JSONValue {
        let input = try checkedInput(resource, raw)
        let key = resource.key?(input) ?? input.queryKey
        guard let record = mirror?.record(kind: resource.kind, scope: cacheScope, key: key) else {
            return notFetched(resource.fetcher, input: input)
        }
        let freshness = Freshness(syncedAt: record.updatedAt, maxAge: maxAge, refresh: ["fetcher": .string(resource.fetcher), "input": input], now: now())
        return Self.answer(resource.key == nil ? record.value["data"] ?? .null : record.value, freshness)
    }

    /// `{stored, unchanged, keys, synced_at, read_with}`.
    nonisolated static func receipt(stored: Int, unchanged: Int, keys: [String], syncedAt: Date, readWith: String) -> JSONValue {
        ["stored": .number(Double(stored)), "unchanged": .number(Double(unchanged)), "keys": .array(keys.map(JSONValue.string)),
         "synced_at": .string(syncedAt.formatted(.iso8601)), "read_with": .string(readWith)]
    }

    /// Objects get the freshness fields; lists come as `items`.
    nonisolated static func answer(_ data: JSONValue, _ freshness: Freshness) -> JSONValue {
        switch data {
        case .object: data.merging(freshness.json)
        case .array: JSONValue.object(["items": data]).merging(freshness.json)
        default: JSONValue.object(["text": data]).merging(freshness.json)
        }
    }

    /// Drops this kind's records stored before `cutoff`.
    func expire(_ kind: String, before cutoff: Date) {
        guard let mirror else { return }
        let records = mirror.records(kind: kind, scope: cacheScope)
        let kept = records.filter { $0.updatedAt >= cutoff }
        if kept.count < records.count { mirror.replace(kind: kind, scope: cacheScope, with: kept) }
    }
}
