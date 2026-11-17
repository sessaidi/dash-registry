import DashKit
import Foundation

/// What Dash fetched from Jira and Confluence is kept in its mirror of online data
/// (`host.synced`), only what was asked for. Online stays the source of truth: a record is fresh
/// for `cacheMinutes`, then readers flag it stale until it's fetched again. Every stored value
/// goes through `Sanitizer` first.
extension AtlassianIntegration {
    /// Mirror kinds and what Settings calls them.
    static let cacheKinds: [(kind: String, label: String)] = [
        ("confluence.doc", "Confluence docs (knowledge)"), ("confluence.page", "Confluence pages"), ("confluence.search", "Confluence searches"),
        ("confluence.hit", "Confluence search hits"), ("confluence.children", "Confluence child lists"),
        ("confluence.attachments", "Confluence attachment lists"), ("confluence.spaces", "Confluence space lists"),
        ("jira.issue", "Jira issues"), ("jira.search", "Jira searches"), ("jira.my_issues", "Jira issues assigned to me"), ("jira.hit", "Jira search hits"), ("jira.comments", "Jira comment lists"),
        ("jira.changelog", "Jira changelogs"), ("jira.projects", "Jira project lists"),
    ]

    /// What `atlassian_cached` looks through: not the stored search answers, whose hits are kept one by one.
    static let lookupKinds = cacheKinds.map(\.kind).filter { !["confluence.search", "jira.search", "jira.my_issues"].contains($0) }

    /// Records are per site.
    var cacheScope: String { siteURL?.host() ?? "atlassian" }

    /// Stores one value (sanitized) in the mirror.
    func remember(_ kind: String, key: String, value: JSONValue) {
        mirror?.upsert([SyncedRecord(kind: kind, scope: cacheScope, key: key, value: Sanitizer.clean(value), source: id, updatedAt: now())])
    }

    func cachedCount(_ kind: String) -> Int { mirror?.records(kind: kind, scope: cacheScope).count ?? 0 }

    /// Forgets everything cached for this site (online data is untouched).
    func clearCache() {
        for (kind, _) in Self.cacheKinds { mirror?.replace(kind: kind, scope: cacheScope, with: []) }
    }
}
