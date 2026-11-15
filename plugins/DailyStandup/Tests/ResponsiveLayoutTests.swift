import AppKit
import DashKit
import DashKitUI
import SwiftUI
import Testing

/// A size in each family, like the gallery's presets and a short wide card.
enum FamilySizes {
    static let all: [(WidgetLayout.Family, CGSize)] = [
        (.narrow, CGSize(width: 272, height: 200)),
        (.medium, CGSize(width: 480, height: 320)),
        (.wide, CGSize(width: 752, height: 300)),
        (.large, CGSize(width: 752, height: 480)),
    ]

    static func size(_ family: WidgetLayout.Family) -> CGSize { all.first { $0.0 == family }!.1 }

    /// Lays `view` out at `size` with that size's widget layout, as the dashboard does.
    @MainActor
    static func render(_ view: some View, at size: CGSize) -> NSView {
        let host = NSHostingView(rootView: view.environment(\.widgetLayout, WidgetLayout(size: size)).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }
}

@Suite("Daily Standup widget layouts")
@MainActor
struct StandupLayoutTests {
    @Test(arguments: FamilySizes.all.map(\.0))
    func buildsForEachFamily(_ family: WidgetLayout.Family) {
        let size = FamilySizes.size(family)
        #expect(WidgetLayout.family(for: size) == family)
        for tab in ["me", "meeting", "blockers"] {
            #expect(FamilySizes.render(DailyStandupWidget.preview(config: .init(tab: tab)), at: size).fittingSize.width > 0)
        }
        // Nothing prepared, the standup live, no blockers.
        var live = StandupState()
        live.myName = "Sadik"
        live.live = ["meeting_id": "m1", "speaking_now": "Ada", "speakers": [["name": "Ada", "words": 40]], "not_heard_yet": ["Sadik"], "named": true]
        #expect(live.upSoon)
        let view = StandupLayout(state: live, tab: .constant("me"), commands: StandupCommands(prepare: {}))
        #expect(FamilySizes.render(view, at: size).fittingSize.width > 0)
    }

    @Test func sampleDayFillsEveryColumn() {
        let sample = StandupState.sample
        #expect(sample.update?.today.isEmpty == false)
        #expect(sample.report?.people.count ?? 0 >= 3)
        #expect(sample.blockers.count == 2 && sample.staleBlockers == 1)
        #expect(!sample.upSoon)
    }
}
