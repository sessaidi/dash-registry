import DashKit
import Foundation
import SwiftData

/// Synced tickets for Dash's knowledge graph. Commits and PRs that mention a key link to it.
extension JiraBoardFeature {
    var knowledge: [KnowledgeEntity] {
        guard let context = host?.context else { return [] }
        return ((try? context.fetch(FetchDescriptor<JiraIssue>())) ?? []).map { issue in
            let text = [issue.issueType, "Status \(issue.statusName)", issue.priority.map { "priority \($0)" },
                        issue.assignee.map { "assigned to \($0)" }, issue.labels.isEmpty ? nil : "labels \(issue.labels.joined(separator: ", "))"]
                .compactMap { $0 }.joined(separator: " · ")
            return KnowledgeEntity(id: "ticket:\(issue.key)", kind: "ticket", title: "\(issue.key) \(issue.summary)", text: text,
                                   url: URL(string: issue.url), updated: issue.updated)
        }
    }

    /// Followed and board tickets by the day they last changed.
    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "updated", title: "Tickets updated", unit: "tickets", systemImage: "checklist") { [weak self] interval in
            let issues = (try? self?.host?.context.fetch(FetchDescriptor<JiraIssue>())) ?? []
            return ActivitySeries.countPerDay(issues.compactMap(\.updated), in: interval)
        }]
    }
}
