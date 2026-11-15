import DashKit

/// Dashii tools (read-only).
extension BackendMeetingFeature {
    var tools: [DashiiTool] {
        [DashiiTool(name: "backend_meeting_reports",
                    description: "The user's past backend meeting reports (highlights per cycle), newest first, with their date ranges.",
                    properties: ["limit": JSONSchema.integer("How many (default 3).")]) { [weak self] input in
            guard let self else { return nil }
            let limit = min(max(input["limit"]?.int ?? 3, 1), 20)
            return .array(reports(limit: limit).map {
                ["start": .string(ReportRange.day($0.start)), "end": .string(ReportRange.day($0.end)), "markdown": .string($0.markdown)]
            })
        }]
    }
}
