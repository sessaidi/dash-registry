import DashKit
import DashKitUI
import SwiftUI

/// The widget body: Me, Meeting and Blockers tabs over the live feature.
struct StandupWidgetView: View {
    @Binding var tab: String
    let standup: DailyStandupFeature?

    var body: some View {
        if let standup {
            VStack(alignment: .leading, spacing: 8) {
                // Short labels so the tabs fit a narrow widget; the Zoom note is in the help.
                Picker("View", selection: $tab) {
                    Text("Me").tag("me")
                    Text("Meeting").tag("meeting")
                    Text("Blockers").tag("blockers")
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(minWidth: 0, maxWidth: .infinity)
                .help(standup.isZoomDay() ? "Today's standup is on Zoom" : "The standup isn't on Zoom today")
                switch tab {
                case "meeting": MeetingView(standup: standup)
                case "blockers": BlockersView(standup: standup)
                default: MeView(standup: standup)
                }
            }
        } else {
            StateView(.failed(message: "Daily Standup isn't loaded."))
        }
    }
}
