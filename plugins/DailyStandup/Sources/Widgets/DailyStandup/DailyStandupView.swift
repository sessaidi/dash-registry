import DashKit
import DashKitUI
import SwiftUI

/// The widget body: today's standup read from the live feature, laid out per size by `StandupLayout`.
struct StandupWidgetView: View {
    @Binding var tab: String
    let standup: DailyStandupFeature?
    @Environment(\.widgetLayout) private var layout
    @State private var prepareError: String?

    var body: some View {
        if let standup {
            StandupLayout(state: state(standup), tab: $tab, commands: StandupCommands(
                prepare: { prepare(standup) },
                resolve: { id in if let blocker = standup.openBlockers().first(where: { $0.id == id }) { standup.resolve(blocker) } }))
            .widgetHeader {
                // Medium shows one section at a time: pick it in the header, not in a row of the card.
                if layout.family == .medium { StandupTabPicker(tab: $tab, isZoomDay: standup.isZoomDay()) }
            }
        } else {
            StateView(.failed(message: "Daily Standup isn't loaded."))
        }
    }

    private func state(_ standup: DailyStandupFeature) -> StandupState {
        let _ = standup.revision
        let day = standup.day()
        let live = standup.live.flatMap { $0["meeting_id"] != nil && day?.report == nil ? $0 : nil }
        return StandupState(
            update: day?.update, preparedAt: day?.preparedAt,
            unpreparedTitle: standup.isWorkday() ? "Not prepared yet" : standup.calendar.skip(on: .now)?.reason ?? "No standup today",
            time: standup.time, prepareMinutesBefore: standup.prepareMinutesBefore, isZoomDay: standup.isZoomDay(),
            isPreparing: standup.isPreparing, isReporting: standup.isReporting, error: prepareError ?? standup.lastError,
            live: live, myName: standup.myName, report: day?.report, notePath: day?.notePath ?? "",
            blockers: standup.openBlockers().map {
                StandupBlockerRow(id: $0.id, text: $0.text, owner: $0.owner, reference: $0.reference, daysOpen: $0.daysOpen)
            })
    }

    private func prepare(_ standup: DailyStandupFeature) {
        Task {
            do { try await standup.prepare(); prepareError = nil } catch { prepareError = error.localizedDescription }
        }
    }
}
