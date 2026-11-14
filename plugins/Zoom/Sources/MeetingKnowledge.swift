import DashKit
import Foundation
import SwiftData

/// Meetings for Dash's knowledge graph: who took part, the summary and decisions (ticket keys
/// said or written in them are linked by Dash).
extension ZoomExtension {
    var knowledge: [KnowledgeEntity] {
        guard let context = host?.context else { return [] }
        return ((try? context.fetch(FetchDescriptor<MeetingRecord>())) ?? []).map { meeting in
            var text = meeting.summary
            if !meeting.decisions.isEmpty { text += "\n\nDecisions:\n" + meeting.decisions.map { "- \($0)" }.joined(separator: "\n") }
            return KnowledgeEntity(
                id: "meeting:\(meeting.id.uuidString)", kind: "meeting",
                title: "\(meeting.title) (\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)))", text: text,
                updated: meeting.endedAt ?? meeting.startedAt,
                links: meeting.participants.map { KnowledgeLink(to: "person:\($0)", kind: "attended_by") })
        }
    }

    /// Meetings per day, and hours spent in them.
    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "meetings", title: "Meetings", unit: "meetings", systemImage: "video") { [weak self] interval in
            let meetings = (try? self?.host?.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
            return ActivitySeries.countPerDay(meetings.map(\.startedAt), in: interval)
         },
         ActivitySeries(id: "hours", title: "Hours in meetings", unit: "h", systemImage: "clock") { [weak self] interval in
            let meetings = (try? self?.host?.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
            return ActivitySeries.sumPerDay(meetings.compactMap { meeting in
                meeting.endedAt.map { (meeting.startedAt, $0.timeIntervalSince(meeting.startedAt) / 3600) }
            }, in: interval)
         }]
    }
}
