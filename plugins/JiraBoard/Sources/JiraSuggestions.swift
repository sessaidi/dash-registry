import DashKit
import Foundation
import SwiftData

/// Home suggestions from the issues already synced: nothing here calls Jira.
extension JiraBoardFeature {
    static let urgentPriorities: Set<String> = ["highest", "blocker", "critical", "high", "p0", "p1"]

    var suggestions: [Suggestion] {
        guard let context = host?.context else { return [] }
        let followed = ((try? context.fetch(FetchDescriptor<JiraIssue>(sortBy: [SortDescriptor(\.updated, order: .reverse)]))) ?? [])
            .filter { $0.followed && $0.statusCategory != "done" }
        var result: [Suggestion] = []

        let urgent = followed.filter { Self.urgentPriorities.contains(($0.priority ?? "").lowercased()) && $0.statusCategory == "new" }
        if let first = urgent.first {
            result.append(Suggestion(
                id: "jira-board.urgent",
                title: urgent.count == 1 ? "\(first.key) is \(first.priority ?? "urgent") and not started" : "\(urgent.count) urgent tickets not started",
                detail: urgent.prefix(3).map { "\($0.key) \($0.summary)" }.joined(separator: " · "),
                icon: "flame", priority: .urgent,
                prompt: "Look at my not-started urgent Jira tickets (\(urgent.map(\.key).joined(separator: ", "))) and propose which to pick up first and a plan for it.",
                link: urgent.count == 1 ? URL(string: first.url) : nil, items: Self.items(urgent)))
        }

        let inProgress = followed.filter { $0.statusCategory == "indeterminate" }
        if !inProgress.isEmpty {
            result.append(Suggestion(
                id: "jira-board.in-progress",
                title: inProgress.count == 1 ? "Continue \(inProgress[0].key)" : "\(inProgress.count) tickets in progress",
                detail: inProgress.prefix(3).map { "\($0.key) \($0.summary)" }.joined(separator: " · "),
                icon: "arrow.forward.circle", priority: inProgress.count > 3 ? .high : .normal,
                prompt: inProgress.count > 3
                    ? "I have \(inProgress.count) tickets in progress. Help me pick what to finish first and what to move back."
                    : "Summarise where my in-progress tickets stand (\(inProgress.map(\.key).joined(separator: ", "))) and the next step for each.",
                items: Self.items(inProgress)))
        }

        let recent = followed.filter { ($0.updated ?? .distantPast) > Date.now.addingTimeInterval(-86_400) && $0.statusCategory != "indeterminate" }
        if !recent.isEmpty {
            result.append(Suggestion(
                id: "jira-board.recent",
                title: recent.count == 1 ? "\(recent[0].key) changed today" : "\(recent.count) followed tickets changed today",
                detail: recent.prefix(3).map { "\($0.key) · \($0.statusName)" }.joined(separator: ", "),
                icon: "bell.badge", priority: .low,
                prompt: "What changed today on the Jira tickets I follow (\(recent.map(\.key).joined(separator: ", ")))?",
                items: Self.items(recent)))
        }
        return result
    }

    var events: [EventDefinition] {
        [EventDefinition("issue.appeared", "A ticket appeared on the board or in the followed list."),
         EventDefinition("issue.status_changed", "A followed ticket moved to another status.")]
    }

    /// The tickets a suggestion is about, listed when its card is opened.
    static func items(_ issues: [JiraIssue]) -> [Suggestion.Item] {
        issues.prefix(30).map { issue in
            Suggestion.Item(title: "\(issue.key) \(issue.summary)",
                            subtitle: [issue.statusName, issue.priority].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            link: URL(string: issue.url))
        }
    }
}
