import DashKit
import DashKitUI
import SwiftUI

/// Backend Meeting: the latest report, past reports and Generate.
struct BackendMeetingWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// The cycle in weeks (1–10).
        var cycleWeeks: Int = 2
        /// Start where the previous report ended (else always the last `cycleWeeks` weeks).
        var sinceLastReport: Bool = true
    }

    static let kind = "backend-meeting.report"
    static let displayName = "Backend Meeting"
    static let summary = "Your highlights for the backend meeting: what you shipped and what's in progress since the last report, grouped into themes."
    static let systemImage = "person.2.wave.2"
    static let defaultSize = WidgetSize.large
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 24)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "cycleWeeks": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Cycle length in weeks."],
            "sinceLastReport": ["type": "boolean", "description": "Start where the previous report ended."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        if let feature = context.host.ext(BackendMeetingFeature.self) {
            BackendMeetingView(feature: feature, config: config)
        } else {
            StateView(.failed(message: "Backend Meeting isn't loaded."))
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        CyclePicker(weeks: config.cycleWeeks)
        Toggle("Start where the last report ended", isOn: config.sinceLastReport)
    }

    /// The same responsive layout over sample reports: no network, no accounts.
    static func preview(config: Config) -> some View {
        BackendMeetingLayout(reports: ReportDigest.samples, config: .constant(config))
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let report = context.host.ext(BackendMeetingFeature.self)?.reports(limit: 1).first else { return ["report": .null] }
        return ["range": .string(report.rangeLabel), "report": .string(report.markdown)]
    }
}

struct CyclePicker: View {
    @Binding var weeks: Int

    var body: some View {
        Picker("Cycle", selection: $weeks) {
            ForEach(1...10, id: \.self) { Text($0 == 1 ? "1 week" : "\($0) weeks").tag($0) }
        }
    }
}
