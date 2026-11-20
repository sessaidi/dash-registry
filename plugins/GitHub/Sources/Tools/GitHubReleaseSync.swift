import DashKit
import Foundation
import Ingestor

/// Mirrors what release timelines need from GitHub into Dash's synced store: a repository's tags
/// (commit, date, whether the commit is on the default branch) and the commits between two
/// commits. Online is the source of truth: tags are replaced on every sync; a range between two
/// fixed commits never changes, so it's fetched once.
extension GitHubIntegration {
    static let tagKind = "git.tag"
    static let rangeKind = "git.range"
    static let repoKind = "git.repo"

    nonisolated static func scope(_ repo: String) -> String { "github:" + repo }

    /// The GraphQL endpoint next to the REST root (github.com, or GitHub Enterprise's /api/graphql).
    var graphQLURL: URL? {
        let api = apiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return URL(string: api.hasSuffix("/api/v3") ? String(api.dropLast(3)) + "graphql" : api + "/graphql")
    }

    static let tagsQuery = """
        query($owner: String!, $name: String!, $after: String) {
          repository(owner: $owner, name: $name) {
            refs(refPrefix: "refs/tags/", first: 100, after: $after) {
              pageInfo { hasNextPage endCursor }
              nodes { name target { __typename oid
                ... on Commit { committedDate messageHeadline }
                ... on Tag { message tagger { date } target { oid ... on Commit { committedDate messageHeadline } } } } }
            }
          }
        }
        """

    /// One tag from the GraphQL answer: annotated tags carry their tagger date (like git's creatordate).
    nonisolated static func tagRecord(_ node: JSONValue, scope: String) -> (name: String, commit: String, date: String, subject: String)? {
        guard let name = node["name"]?.string, let target = node["target"] else { return nil }
        if target["__typename"]?.string == "Tag" {
            guard let commit = target["target"]?["oid"]?.string else { return nil }
            let date = target["tagger"]?["date"]?.string ?? target["target"]?["committedDate"]?.string ?? ""
            let subject = target["message"]?.string?.split(separator: "\n").first.map(String.init) ?? ""
            return (name, commit, date, subject)
        }
        guard let commit = target["oid"]?.string else { return nil }
        return (name, commit, target["committedDate"]?.string ?? "", target["messageHeadline"]?.string ?? "")
    }

    /// Syncs a repository's tags into the mirror. Returns how many there are.
    @discardableResult
    func syncTags(_ repo: String, store: any SyncedStore) async throws -> Int {
        guard let connection, let graphQL = graphQLURL else { throw ToolError("Connect GitHub in Settings first.") }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw ToolError("Give repo as owner/name.") }
        let scope = Self.scope(repo)
        let info = try await connection.get("/repos/\(repo)", service: "GitHub")
        let defaultBranch = info["default_branch"]?.string ?? "main"
        var tags: [(name: String, commit: String, date: String, subject: String)] = []
        var after: JSONValue = .null
        repeat {
            var request = try HTTP.request(graphQL, method: "POST", body: ["query": .string(Self.tagsQuery),
                                                                          "variables": ["owner": .string(parts[0]), "name": .string(parts[1]), "after": after]])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await connection.send(request, service: "GitHub")
            let page = try JSONValue.parse(data)
            if let message = page["errors"]?[0]?["message"]?.string { throw ToolError("GitHub: \(message)") }
            let refs = page["data"]?["repository"]?["refs"]
            tags += (refs?["nodes"]?.array ?? []).compactMap { Self.tagRecord($0, scope: scope) }
            after = refs?["pageInfo"]?["hasNextPage"]?.bool == true ? (refs?["pageInfo"]?["endCursor"] ?? .null) : .null
        } while after != .null && tags.count < 5_000
        // Whether each commit is on the default branch: reused from the mirror while the tag still
        // points at the same commit, asked for otherwise.
        let known = Dictionary(store.records(kind: Self.tagKind, scope: scope).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var onBase: [String: Bool] = [:]
        let unknown = tags.filter { known[$0.name]?["commit"]?.string != $0.commit || known[$0.name]?["on_base"]?.bool == nil }
        for (name, value) in known { if let flag = value["on_base"]?.bool { onBase[name] = flag } }
        // Six compares at a time.
        for start in stride(from: 0, to: unknown.count, by: 6) {
            let batch = Array(unknown[start..<min(start + 6, unknown.count)])
            let tasks = batch.map { tag in
                Task { @MainActor in
                    let compare = try await connection.get("/repos/\(repo)/compare/\(defaultBranch)...\(tag.commit)", service: "GitHub")
                    return (name: tag.name, onBase: ["behind", "identical"].contains(compare["status"]?.string ?? ""))
                }
            }
            var flags: [(name: String, onBase: Bool)] = []
            for task in tasks { flags.append(try await task.value) }
            for flag in flags { onBase[flag.name] = flag.onBase }
        }
        store.replace(kind: Self.tagKind, scope: scope, with: tags.map { tag in
            SyncedRecord(kind: Self.tagKind, scope: scope, key: tag.name,
                         value: Sanitizer.clean(["commit": .string(tag.commit), "date": .string(tag.date), "subject": .string(tag.subject),
                                                 "on_base": .bool(onBase[tag.name] ?? true)]), source: id)
        })
        store.replace(kind: Self.repoKind, scope: scope, with: [
            SyncedRecord(kind: Self.repoKind, scope: scope, key: "info", value: ["default_branch": .string(defaultBranch)], source: id),
        ])
        return tags.count
    }

    /// The commits in `head` but not in `base` (merges left out), mirrored once: the range between
    /// two commits never changes.
    func syncRange(_ repo: String, base: String, head: String, store: any SyncedStore) async throws -> [JSONValue] {
        let scope = Self.scope(repo)
        let key = base + "..." + head
        if let cached = store.record(kind: Self.rangeKind, scope: scope, key: key)?.value.array { return cached }
        guard let connection else { throw ToolError("Connect GitHub in Settings first.") }
        var commits: [JSONValue] = []
        var page = 1
        while page <= 20 {
            let compare = try await connection.get("/repos/\(repo)/compare/\(base)...\(head)?per_page=100&page=\(page)", service: "GitHub")
            let items = compare["commits"]?.array ?? []
            commits += items.filter { ($0["parents"]?.array?.count ?? 1) <= 1 }.map { item in
                ["sha": item["sha"] ?? .null, "author": item["commit"]?["author"]?["name"] ?? .null,
                 "date": item["commit"]?["author"]?["date"] ?? .null,
                 "subject": .string(String((item["commit"]?["message"]?.string ?? "").split(separator: "\n").first ?? ""))]
            }
            if items.count < 100 { break }
            page += 1
        }
        commits = commits.map(Sanitizer.clean)
        store.upsert([SyncedRecord(kind: Self.rangeKind, scope: scope, key: key, value: .array(commits), source: id)])
        return commits
    }

    /// "owner/name" as given (Releases keys its mirror by it), checked.
    nonisolated static func slug(_ input: JSONValue) throws -> String {
        let repo = input["repo"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = try repoPath(["repo": .string(repo)])
        return repo
    }

    /// For other extensions (Releases runs them by name): they call GitHub, so Dashii and agents
    /// never get them; they use the github.tags and github.range fetchers.
    var syncTools: [DashiiTool] {
        [
            DashiiTool(name: "github_sync_tags",
                       description: "Mirror a repository's tags (commit, date, on the default branch or not) from GitHub into Dash, for release timelines. Reads GitHub only; replaces the local mirror with what GitHub has.",
                       properties: ["repo": JSONSchema.string("owner/name")], required: ["repo"], callsService: true) { [weak self] input in
                guard let self, let host else { return nil }
                let count = try await syncTags(input["repo"]?.string ?? "", store: host.synced)
                return ["tags": .number(Double(count))]
            },
            DashiiTool(name: "github_sync_compare",
                       description: "Mirror the commits between two commits or tags of a repository (merges left out) from GitHub into Dash. Reads GitHub only.",
                       properties: ["repo": JSONSchema.string("owner/name"), "base": JSONSchema.string("Base commit or tag."), "head": JSONSchema.string("Head commit or tag.")],
                       required: ["repo", "base", "head"], callsService: true) { [weak self] input in
                guard let self, let host else { return nil }
                return .array(try await syncRange(input["repo"]?.string ?? "", base: input["base"]?.string ?? "", head: input["head"]?.string ?? "", store: host.synced))
            },
        ]
    }

    private static let rangeProperties: [String: JSONValue] = [
        "repo": JSONSchema.string("owner/name"), "base": JSONSchema.string("Base commit or tag."), "head": JSONSchema.string("Head commit or tag."),
    ]

    private static func rangeInput(_ input: JSONValue) throws -> (repo: String, base: String, head: String) {
        let repo = try slug(input)
        let base = input["base"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = input["head"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty, !head.isEmpty else { throw ToolError("Give base and head.") }
        return (repo, base, head)
    }

    var releaseFetchers: [DataFetcher] {
        [
            DataFetcher(name: "github.tags", summary: "A repository's tags (commit, date, on the default branch or not), for release timelines. Read them with github_tags.",
                        properties: ["repo": JSONSchema.string("owner/name")], required: ["repo"]) { [weak self] input in
                guard let self, let host else { return nil }
                let repo = try Self.slug(input)
                let scope = Self.scope(repo)
                let before = Dictionary(host.synced.records(kind: Self.tagKind, scope: scope).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
                try await syncTags(repo, store: host.synced)
                let after = host.synced.records(kind: Self.tagKind, scope: scope)
                let changed = after.filter { before[$0.key] != $0.value }.map(\.key)
                IngestNotification.post(fetcher: "github.tags", kind: Self.tagKind, scope: scope, key: "")
                return IngestReceipt(stored: changed.count, unchanged: after.count - changed.count, keys: changed.prefix(50).map { Self.tagKind + "/" + $0 },
                                     syncedAt: host.synced.lastSynced(kind: Self.tagKind, scope: scope) ?? now(),
                                     readWith: "github_tags " + (["repo": .string(repo)] as JSONValue).jsonString()).json
            },
            DataFetcher(name: "github.range", summary: "The commits between two commits or tags of a repository (merges left out). Read them with github_range.",
                        properties: Self.rangeProperties, required: ["repo", "base", "head"]) { [weak self] input in
                guard let self, let host else { return nil }
                let (repo, base, head) = try Self.rangeInput(input)
                let key = base + "..." + head
                let had = host.synced.record(kind: Self.rangeKind, scope: Self.scope(repo), key: key) != nil
                _ = try await syncRange(repo, base: base, head: head, store: host.synced)
                let syncedAt = host.synced.record(kind: Self.rangeKind, scope: Self.scope(repo), key: key)?.updatedAt ?? now()
                IngestNotification.post(fetcher: "github.range", kind: Self.rangeKind, scope: Self.scope(repo), key: key)
                return IngestReceipt(stored: had ? 0 : 1, unchanged: had ? 1 : 0, keys: [Self.rangeKind + "/" + key], syncedAt: syncedAt,
                                     readWith: "github_range " + (["repo": .string(repo), "base": .string(base), "head": .string(head)] as JSONValue).jsonString()).json
            },
        ]
    }

    var releaseReaders: [DashiiTool] {
        [
            DashiiTool(name: "github_tags",
                       description: "A repository's tags as Dash mirrored them (commit, date, subject, on the default branch), newest first, with synced_at and stale. Fetch with data_fetch github.tags.",
                       properties: ["repo": JSONSchema.string("owner/name")], required: ["repo"]) { [weak self] input in
                guard let self, let host else { return nil }
                let repo = try Self.slug(input)
                let scope = Self.scope(repo)
                guard let synced = host.synced.lastSynced(kind: Self.tagKind, scope: scope) else { return notFetched("github.tags", input: ["repo": .string(repo)]) }
                let freshness = Freshness(syncedAt: synced, maxAge: maxAge, refresh: ["fetcher": "github.tags", "input": ["repo": .string(repo)]], now: now())
                let tags = host.synced.records(kind: Self.tagKind, scope: scope).map { $0.value.merging(["tag": .string($0.key)]) }
                    .sorted { ($0["date"]?.string ?? "") > ($1["date"]?.string ?? "") }
                return Ingestor.answer(.array(Array(tags.prefix(200))), freshness).merging(["total": .number(Double(tags.count))])
            },
            DashiiTool(name: "github_range",
                       description: "The commits between two commits or tags (merges left out) as Dash mirrored them. Fetch with data_fetch github.range.",
                       properties: Self.rangeProperties, required: ["repo", "base", "head"]) { [weak self] input in
                guard let self, let host else { return nil }
                let (repo, base, head) = try Self.rangeInput(input)
                let refresh: JSONValue = ["fetcher": "github.range", "input": ["repo": .string(repo), "base": .string(base), "head": .string(head)]]
                guard let record = host.synced.record(kind: Self.rangeKind, scope: Self.scope(repo), key: base + "..." + head) else {
                    return notFetched("github.range", input: refresh["input"] ?? [:])
                }
                // The commits between two commits never change.
                return Ingestor.answer(record.value, Freshness(syncedAt: record.updatedAt, maxAge: .seconds(10 * 365 * 86_400), refresh: refresh, now: now()))
            },
        ]
    }
}
