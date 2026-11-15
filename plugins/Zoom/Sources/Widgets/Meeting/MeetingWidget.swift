import DashKit
import DashKitUI
import SwiftUI

/// Meeting: the live Zoom transcript and participants, recent meetings otherwise.
struct MeetingWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var recentCount: Int
    }

    static let kind = "zoom.meeting"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 8, maxH: 20)
    static let displayName = "Meeting"
    static let summary = "Live Zoom transcript and participants while a meeting runs; recent meeting summaries otherwise."
    static let systemImage = "video"
    static let defaultSize = WidgetSize.large
    static let defaultConfig = Config(recentCount: 5)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["recentCount": ["type": "integer", "description": "How many past meetings to list."]],
    ]

    static let queryFields = MeetingRecord.queryFields

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        MeetingPanel(zoom: context.host.ext(ZoomExtension.self), host: context.host, recentCount: config.wrappedValue.recentCount,
                     query: context.query(fields: MeetingRecord.queryFields), queryText: context.queryText)
    }

    static func preview(config: Config) -> some View {
        MeetingPreview()
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let zoom = context.host.ext(ZoomExtension.self) else { return .null }
        return ["recording": .bool(zoom.isRecording), "participants": .array(zoom.participants.map { .string($0) }),
                "current_meeting": zoom.currentMeeting?.json ?? .null]
    }
}
