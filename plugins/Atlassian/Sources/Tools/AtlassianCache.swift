import DashKit
import Foundation

/// What Claude reads from Jira and Confluence is kept in Dash's mirror of online data
/// (`host.synced`), only what was asked for. Online stays the source of truth: a record is reused
/// while it's younger than `cacheMinutes`, refetched after, and served stale (flagged) when the
/// site can't be reached. Every stored value goes through `Sanitizer` first.
extension AtlassianIntegration {
    /// Mirror kinds and what Settings calls them.
    static let cacheKinds: [(kind: String, label: String)] = [
        ("confluence.doc", "Confluence docs (knowledge)"), ("confluence.page", "Confluence pages"), ("confluence.hit", "Confluence search hits"), ("confluence.children", "Confluence child lists"),
        ("confluence.attachments", "Confluence attachment lists"), ("confluence.spaces", "Confluence space lists"),
        ("jira.issue", "Jira issues"), ("jira.hit", "Jira search hits"), ("jira.comments", "Jira comment lists"),
        ("jira.changelog", "Jira changelogs"), ("jira.projects", "Jira project lists"),
    ]

    /// Records are per site.
    var cacheScope: String { siteURL?.host() ?? "atlassian" }

    /// `fetch`'s result, or the mirror's copy while it's fresh. `fresh` always goes online; when
    /// online fails, a cached copy is returned with `stale: true` and the error.
    func cached(_ kind: String, key: String, fresh: Bool, fetch: () async throws -> JSONValue) async throws -> JSONValue {
        let existing = mirror?.record(kind: kind, scope: cacheScope, key: key)
        if !fresh, let existing, now().timeIntervalSince(existing.updatedAt) < Double(cacheMinutes) * 60 {
            return marked(existing.value, fromCache: true, at: existing.updatedAt)
        }
        do {
            let value = Sanitizer.clean(try await fetch())
            remember(kind, key: key, value: value)
            return marked(value, fromCache: false, at: now())
        } catch let error where existing != nil {
            return marked(existing!.value, fromCache: true, at: existing!.updatedAt)
                .merging(["stale": true, "error": .string(error.localizedDescription)])
        }
    }

    /// Stores one value (sanitized) in the mirror.
    func remember(_ kind: String, key: String, value: JSONValue) {
        mirror?.upsert([SyncedRecord(kind: kind, scope: cacheScope, key: key, value: Sanitizer.clean(value), source: id, updatedAt: now())])
    }

    private func marked(_ value: JSONValue, fromCache: Bool, at date: Date) -> JSONValue {
        let stamp: JSONValue = ["from_cache": .bool(fromCache), "synced_at": .string(date.formatted(.iso8601))]
        if value.object != nil { return value.merging(stamp) }
        return stamp.merging(["items": value])
    }

    func cachedCount(_ kind: String) -> Int { mirror?.records(kind: kind, scope: cacheScope).count ?? 0 }

    /// Forgets everything cached for this site (online data is untouched).
    func clearCache() {
        for (kind, _) in Self.cacheKinds { mirror?.replace(kind: kind, scope: cacheScope, with: []) }
    }
}
