import DashKit
import Foundation

/// Fetch, then read: fetchers store GitHub's answers in Dash's mirror (`host.synced`), sanitized
/// and capped at 200 KB; the Dashii tools read them back with their freshness. Records are per
/// API host (github.com or an Enterprise server), kind `github.<what>`, keyed by the normalized
/// input's hash; the value keeps the input next to the data.
extension GitHubIntegration {
    /// Query-shaped answers older than this are dropped when their kind is stored again.
    static let queryRetention: TimeInterval = 86_400

    var storeScope: String { "github:" + (URL(string: apiURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host() ?? "api.github.com") }
    var maxAge: Duration { .seconds(freshMinutes * 60) }

    var fetchers: [DataFetcher] {
        resources.map { resource in
            DataFetcher(name: resource.fetcherName, summary: resource.summary + " Read it with \(resource.readerName).",
                        properties: resource.properties, required: resource.required) { [weak self] input in
                guard let self else { return nil }
                return try await fetch(resource, input)
            }
        } + releaseFetchers
    }

    /// The readers Dashii and agents use: same names and inputs as the old live tools.
    var readers: [DashiiTool] {
        resources.map { resource in
            DashiiTool(name: resource.readerName,
                       description: resource.summary + " Reads what Dash fetched (data_fetch \(resource.fetcherName)), with synced_at and stale.",
                       properties: resource.properties, required: resource.required) { [weak self] input in
                guard let self else { return nil }
                return try read(resource, input)
            }
        }
    }

    /// The input as stored and hashed: only the schema's properties, strings trimmed, empty
    /// values dropped, the repository in lower case (GitHub ignores case there).
    nonisolated static func normalized(_ input: JSONValue, properties: [String: JSONValue]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (name, value) in input.object ?? [:] where properties[name] != nil {
            switch value {
            case .null: continue
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[name] = .string(name == "repo" ? trimmed.lowercased() : trimmed) }
            default: result[name] = value
            }
        }
        return .object(result)
    }

    /// The input, normalized and checked (required fields, repository shape).
    func checkedInput(_ resource: GitHubResource, _ raw: JSONValue) throws -> JSONValue {
        let input = Self.normalized(raw, properties: resource.properties)
        let missing = resource.required.filter { input[$0] == nil }
        if !missing.isEmpty { throw ToolError("Give \(missing.joined(separator: " and ")).") }
        if input["repo"] != nil { _ = try Self.repoPath(input) }
        return input
    }

    /// Calls GitHub and stores the answer; returns the receipt.
    func fetch(_ resource: GitHubResource, _ raw: JSONValue) async throws -> JSONValue {
        guard let host else { throw ToolError("GitHub isn't started.") }
        let input = try checkedInput(resource, raw)
        let data = Sanitizer.clean(try await resource.load(self, input)).capped()
        let key = input.queryKey
        let unchanged = host.synced.record(kind: resource.kind, scope: storeScope, key: key)?.value["data"] == data
        let syncedAt = now()
        host.synced.upsert([SyncedRecord(kind: resource.kind, scope: storeScope, key: key, value: ["input": input, "data": data], source: id, updatedAt: syncedAt)])
        if resource.queryShaped { expire(resource.kind, before: syncedAt.addingTimeInterval(-Self.queryRetention)) }
        return Self.receipt(stored: unchanged ? 0 : 1, unchanged: unchanged ? 1 : 0, keys: [resource.kind + "/" + key], syncedAt: syncedAt,
                            readWith: resource.readerName + " " + input.jsonString())
    }

    /// The stored answer with its freshness, or what to fetch.
    func read(_ resource: GitHubResource, _ raw: JSONValue) throws -> JSONValue {
        guard let host else { throw ToolError("GitHub isn't started.") }
        let input = try checkedInput(resource, raw)
        guard let record = host.synced.record(kind: resource.kind, scope: storeScope, key: input.queryKey) else {
            return notFetched(resource.fetcherName, input: input)
        }
        let freshness = Freshness(syncedAt: record.updatedAt, maxAge: maxAge, refresh: ["fetcher": .string(resource.fetcherName), "input": input], now: now())
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
    func expire(_ kind: String, before cutoff: Date) {
        guard let host else { return }
        let records = host.synced.records(kind: kind, scope: storeScope)
        let kept = records.filter { $0.updatedAt >= cutoff }
        if kept.count < records.count { host.synced.replace(kind: kind, scope: storeScope, with: kept) }
    }
}
