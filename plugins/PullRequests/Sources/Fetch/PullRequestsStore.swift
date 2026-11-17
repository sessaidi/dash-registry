import DashKit
import Foundation

/// Fetch, then read: the fetchers store GitHub's answers in Dash's mirror (`host.synced`),
/// sanitized and capped at 200 KB; the Dashii tools read them back with their freshness. Records
/// are per API host (as the GitHub integration's), kind `github.<what>`, keyed by the normalized
/// input's hash; the value keeps the input next to the data.
extension PullRequestsFeature {
    /// PRs move fast: a stored answer is stale after this long.
    static let freshMinutes = 10

    var storeScope: String {
        let api = github?.exports["apiURL"]?.string ?? ""
        return "github:" + (URL(string: api.trimmingCharacters(in: .whitespacesAndNewlines))?.host() ?? "api.github.com")
    }

    var fetchers: [DataFetcher] {
        resources.map { resource in
            DataFetcher(name: resource.fetcherName, summary: resource.summary + " Read it with \(resource.reader).",
                        properties: PullRequestResource.properties, required: PullRequestResource.required) { [weak self] input in
                guard let self else { throw ToolError("Pull Requests isn't ready.") }
                return try await fetch(resource, input)
            }
        } + [branchPullsFetcher]
    }

    /// The input as stored and hashed: the repository trimmed and in lower case, the number.
    nonisolated static func checkedInput(_ raw: JSONValue) throws -> (input: JSONValue, repo: String, number: Int) {
        let repo = (raw["repo"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let number = raw["number"]?.int, !repo.isEmpty else { throw ToolError("Give repo and number.") }
        guard Self.isRepo(repo) else { throw ToolError("Give repo as owner/name.") }
        guard number > 0 else { throw ToolError("Give a PR number.") }
        return (["repo": .string(repo), "number": .number(Double(number))], repo, number)
    }

    nonisolated static func isRepo(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    /// Calls GitHub and stores the answer; returns the receipt.
    func fetch(_ resource: PullRequestResource, _ raw: JSONValue) async throws -> JSONValue {
        guard let host else { throw ToolError("Pull Requests isn't started.") }
        let (input, repo, number) = try Self.checkedInput(raw)
        let data = Sanitizer.clean(try await resource.load(try client, repo, number)).capped()
        let key = input.queryKey
        let unchanged = host.synced.record(kind: resource.kind, scope: storeScope, key: key)?.value["data"] == data
        let syncedAt = now()
        host.synced.upsert([SyncedRecord(kind: resource.kind, scope: storeScope, key: key, value: ["input": input, "data": data], source: id, updatedAt: syncedAt)])
        return Self.receipt(stored: unchanged ? 0 : 1, unchanged: unchanged ? 1 : 0, keys: [resource.kind + "/" + key], syncedAt: syncedAt,
                            readWith: resource.reader + " " + input.jsonString())
    }

    /// The stored answer with its freshness (plus `extra`), or what to fetch.
    func read(_ resource: PullRequestResource, _ raw: JSONValue, extra: (String, Int) -> [String: JSONValue] = { _, _ in [:] }) throws -> JSONValue {
        guard let host else { throw ToolError("Pull Requests isn't started.") }
        let (input, repo, number) = try Self.checkedInput(raw)
        let added = JSONValue.object(extra(repo, number))
        guard let record = host.synced.record(kind: resource.kind, scope: storeScope, key: input.queryKey) else {
            return notFetched(resource.fetcherName, input: input).merging(added)
        }
        let freshness = Freshness(syncedAt: record.updatedAt, maxAge: .seconds(Self.freshMinutes * 60),
                                  refresh: ["fetcher": .string(resource.fetcherName), "input": input], now: now())
        return (record.value["data"] ?? [:]).merging(freshness.json).merging(added)
    }

    /// `{stored, unchanged, keys, synced_at, read_with}`.
    nonisolated static func receipt(stored: Int, unchanged: Int, keys: [String], syncedAt: Date, readWith: String) -> JSONValue {
        ["stored": .number(Double(stored)), "unchanged": .number(Double(unchanged)), "keys": .array(keys.map(JSONValue.string)),
         "synced_at": .string(syncedAt.formatted(.iso8601)), "read_with": .string(readWith)]
    }
}
