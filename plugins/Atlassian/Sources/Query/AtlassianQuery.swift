import DashKit
import Foundation

/// The Confluence and Jira data Dashii already read, for DashQL: `confluence` (pages, or search
/// hits until a page is read) and `jira_cache` (issues read through the Atlassian tools). Offline,
/// from the synced mirror; nothing is fetched.
extension AtlassianIntegration {
    var datasets: [QueryDataset] {
        [
            QueryDataset(name: "confluence", aliases: ["wiki", "pages"], summary: "Confluence pages Dashii read (full pages, else search hits), from the local mirror.",
                         fields: [.init("id", "string", "Page id"), .init("title"), .init("space.key", "string", "Space key", aliases: ["space"]),
                                  .init("updated", "date", "Last edit"), .init("updated_by", "string", "Who edited it last"),
                                  .init("labels", "list"), .init("ancestors.title", "list", "Parent pages", aliases: ["parents"]),
                                  .init("markdown", "string", "Body (full pages)", aliases: ["body"]), .init("excerpt", "string", "Search excerpt (hits)"),
                                  .init("url"), .init("full", "bool", "A full page, not just a hit"), .init("synced_at", "date", "When Dash read it")]) { [weak self] _ in
                self?.mirrorRows(page: "confluence.page", hit: "confluence.hit", key: "id") ?? []
            },
            QueryDataset(name: "jira_cache", aliases: ["issues_read"], summary: "Jira issues Dashii read through the Atlassian tools (with description, links and comments when read in full), from the local mirror. For the board and followed tickets, use `jira`.",
                         fields: [.init("key", "string", "Issue key (joins prs.tickets)", aliases: ["ticket"]), .init("summary"), .init("status"),
                                  .init("type"), .init("priority"), .init("assignee"), .init("updated", "date"), .init("labels", "list"),
                                  .init("description"), .init("links.key", "list", "Linked issues"), .init("url"),
                                  .init("full", "bool", "Read in full, not just a search hit"), .init("synced_at", "date", "When Dash read it")]) { [weak self] _ in
                self?.mirrorRows(page: "jira.issue", hit: "jira.hit", key: "key") ?? []
            },
        ]
    }

    /// Full records first; search hits only for what wasn't read in full. Each with when it was read.
    private func mirrorRows(page: String, hit: String, key: String) -> [JSONValue] {
        guard let mirror else { return [] }
        let full = mirror.records(kind: page, scope: cacheScope)
        let seen = Set(full.map(\.key))
        let hits = mirror.records(kind: hit, scope: cacheScope).filter { !seen.contains($0.key) }
        return (full.map { ($0, true) } + hits.map { ($0, false) }).map { record, isFull in
            record.value.merging(["full": .bool(isFull), "synced_at": .string(record.updatedAt.formatted(.iso8601))])
        }
    }
}
