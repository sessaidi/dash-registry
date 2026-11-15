import DashKit
import DashKitUI
import SwiftUI

/// Daily Standup: your update, the Zoom standup followed live and reported, open blockers.
struct DailyStandupWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// me, meeting or blockers.
        var tab: String
    }

    static let kind = "daily-standup"
    static let displayName = "Daily Standup"
    static let summary = "Your update for today's standup (since yesterday, next steps, blockers), the Zoom standup followed live and its report, and open blockers."
    static let systemImage = "person.3.sequence"
    static let defaultSize = WidgetSize.large
    static let sizeLimits = GridLimits(minW: 4, minH: 6, maxW: 12, maxH: 24)
    static let defaultConfig = Config(tab: "me")
    static let configSchema: JSONValue = ["type": "object", "properties": ["tab": ["type": "string", "enum": ["me", "meeting", "blockers"]]]]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        StandupWidgetView(tab: config.tab, standup: context.host.ext(DailyStandupFeature.self))
    }

    static func preview(config: Config) -> some View {
        StandupUpdateView(update: StandupUpdate(
            yesterday: [StandupItem(text: "Finished the renewal endpoint and its tests", ticket: "LAF-5680", refs: ["a1b2c3d", "api#88"]),
                        StandupItem(text: "Reviewed Sam's checkout PR", ticket: "WEB-412", refs: ["web#412"])],
            today: [StandupItem(text: "Fix the flaky renewal test Dashii flagged", ticket: "LAF-5680", refs: ["api#88"], kind: "fix"),
                    StandupItem(text: "Waiting for review on the renewal PR", ticket: "LAF-5680", refs: ["api#88"], kind: "waiting"),
                    StandupItem(text: "Proration on upgrade", ticket: "LAF-5702", refs: [], kind: "start")],
            blockers: [StandupItem(text: "QA workspace crash-loops (OOM)", ticket: "LAF-5680", refs: ["laf-5680"])]),
            preparedAt: .now, onRefresh: nil)
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let standup = context.host.ext(DailyStandupFeature.self), let day = standup.day() else { return ["prepared": false] }
        return ["update": .string(day.update?.text ?? ""), "report": .string(day.report?.summary ?? "")]
    }
}
