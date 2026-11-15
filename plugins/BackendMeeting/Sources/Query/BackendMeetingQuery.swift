import DashKit
import Foundation
import SwiftData

/// Backend Meeting reports for DashQL: the `reports` dataset.
extension BackendReport {
    static let queryFields: [QueryDataset.Field] = [
        .init("id", "string", "Report id"),
        .init("start", "date", "Cycle start"), .init("end", "date", "Cycle end"),
        .init("weeks", "number", "Cycle length in weeks", aliases: ["cycle"]),
        .init("themes", "list", "The report's bullet themes", aliases: ["bullets"]),
        .init("markdown", "string", "The whole report"),
        .init("created", "date", "When it was written"),
    ]

    var queryRow: JSONValue {
        let themes = markdown.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.firstMatch(of: /^- \*\*(.+?)\*\*/) else { return nil }
            return String(match.output.1)
        }
        return [
            "id": .string(id.uuidString), "start": start.queryValue, "end": end.queryValue, "weeks": .number(Double(cycleWeeks)),
            "themes": .array(themes.map(JSONValue.string)), "markdown": .string(markdown), "created": createdAt.queryValue,
        ]
    }
}

extension BackendMeetingFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "reports", aliases: ["backend_reports", "fait_marquant"], summary: "Backend Meeting reports (fait marquant per cycle), newest first.",
                      fields: BackendReport.queryFields) { [weak self] _ in
            guard let context = self?.host?.context else { return [] }
            return ((try? context.fetch(FetchDescriptor<BackendReport>(sortBy: [SortDescriptor(\.end, order: .reverse)]))) ?? []).map(\.queryRow)
        }]
    }
}
