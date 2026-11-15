import DashKit
import Foundation

/// Mirrors what release timelines need from GitLab into Dash's synced store, in the same shape as
/// the GitHub integration: tags (commit, date, on the default branch or not) and the commits
/// between two commits. Online is the source of truth: tags are replaced on every sync; a range
/// between two fixed commits never changes, so it's fetched once.
extension GitLabIntegration {
    static let tagKind = "git.tag"
    static let rangeKind = "git.range"
    static let repoKind = "git.repo"

    nonisolated static func scope(_ project: String) -> String { "gitlab:" + project }

    /// One tag from /repository/tags: annotated tags carry their creation date.
    nonisolated static func tagRecord(_ tag: JSONValue) -> (name: String, commit: String, date: String, subject: String)? {
        guard let name = tag["name"]?.string, let commit = tag["commit"]?["id"]?.string else { return nil }
        let date = tag["created_at"]?.string ?? tag["commit"]?["committed_date"]?.string ?? ""
        let message = tag["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let subject = message?.split(separator: "\n").first.map(String.init) ?? tag["commit"]?["title"]?.string ?? ""
        return (name, commit, date, subject)
    }

    /// Syncs a project's tags into the mirror. Returns how many there are.
    @discardableResult
    func syncTags(_ project: String, store: any SyncedStore) async throws -> Int {
        let id = Self.projectID(project)
        let scope = Self.scope(project)
        let defaultBranch = try await get("/projects/\(id)")["default_branch"]?.string ?? "main"
        var tags: [(name: String, commit: String, date: String, subject: String)] = []
        var page = 1
        while page <= 50 {
            let items = try await get("/projects/\(id)/repository/tags?per_page=100&page=\(page)").array ?? []
            tags += items.compactMap(Self.tagRecord)
            if items.count < 100 { break }
            page += 1
        }
        // Whether each commit is on the default branch, reused while the tag still points at it.
        let known = Dictionary(store.records(kind: Self.tagKind, scope: scope).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var onBase: [String: Bool] = [:]
        for (name, value) in known { if let flag = value["on_base"]?.bool { onBase[name] = flag } }
        let unknown = tags.filter { known[$0.name]?["commit"]?.string != $0.commit || known[$0.name]?["on_base"]?.bool == nil }
        for start in stride(from: 0, to: unknown.count, by: 6) {
            let tasks = unknown[start..<min(start + 6, unknown.count)].map { tag in
                Task { @MainActor in
                    let base = try await get("/projects/\(id)/repository/merge_base?refs[]=\(defaultBranch)&refs[]=\(tag.commit)")
                    return (name: tag.name, onBase: base["id"]?.string == tag.commit)
                }
            }
            for task in tasks {
                let flag = try await task.value
                onBase[flag.name] = flag.onBase
            }
        }
        store.replace(kind: Self.tagKind, scope: scope, with: tags.map { tag in
            SyncedRecord(kind: Self.tagKind, scope: scope, key: tag.name,
                         value: ["commit": .string(tag.commit), "date": .string(tag.date), "subject": .string(tag.subject),
                                 "on_base": .bool(onBase[tag.name] ?? true)], source: self.id)
        })
        store.replace(kind: Self.repoKind, scope: scope, with: [
            SyncedRecord(kind: Self.repoKind, scope: scope, key: "info", value: ["default_branch": .string(defaultBranch)], source: self.id),
        ])
        return tags.count
    }

    /// The commits in `head` but not in `base` (merges left out), mirrored once.
    func syncRange(_ project: String, base: String, head: String, store: any SyncedStore) async throws -> [JSONValue] {
        let scope = Self.scope(project)
        let key = base + "..." + head
        if let cached = store.record(kind: Self.rangeKind, scope: scope, key: key)?.value.array { return cached }
        let compare = try await get("/projects/\(Self.projectID(project))/repository/compare?from=\(base)&to=\(head)&straight=false")
        let commits: [JSONValue] = (compare["commits"]?.array ?? []).filter { ($0["parent_ids"]?.array?.count ?? 1) <= 1 }.map { item in
            ["sha": item["id"] ?? .null, "author": item["author_name"] ?? .null, "date": item["authored_date"] ?? .null,
             "subject": item["title"] ?? .null]
        }
        store.upsert([SyncedRecord(kind: Self.rangeKind, scope: scope, key: key, value: .array(commits), source: id)])
        return commits
    }

    var syncTools: [ClaudeTool] {
        [
            ClaudeTool(name: "gitlab_sync_tags",
                       description: "Mirror a project's tags (commit, date, on the default branch or not) from GitLab into Dash, for release timelines. Reads GitLab only; replaces the local mirror with what GitLab has.",
                       properties: ["repo": JSONSchema.string("group/project")], required: ["repo"]) { [weak self] input in
                guard let self, let host else { return nil }
                let count = try await syncTags(input["repo"]?.string ?? "", store: host.synced)
                return ["tags": .number(Double(count))]
            },
            ClaudeTool(name: "gitlab_sync_compare",
                       description: "Mirror the commits between two commits or tags of a project (merges left out) from GitLab into Dash. Reads GitLab only.",
                       properties: ["repo": JSONSchema.string("group/project"), "base": JSONSchema.string("Base commit or tag."), "head": JSONSchema.string("Head commit or tag.")],
                       required: ["repo", "base", "head"]) { [weak self] input in
                guard let self, let host else { return nil }
                return .array(try await syncRange(input["repo"]?.string ?? "", base: input["base"]?.string ?? "", head: input["head"]?.string ?? "", store: host.synced))
            },
        ]
    }
}
