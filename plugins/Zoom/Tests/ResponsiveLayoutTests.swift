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

@Suite("Meeting widget layouts")
@MainActor
struct MeetingLayoutTests {
    @Test(arguments: FamilySizes.all.map(\.0))
    func buildsForEachFamily(_ family: WidgetLayout.Family) {
        let size = FamilySizes.size(family)
        #expect(WidgetLayout.family(for: size) == family)
        // Live, idle with past meetings, and nothing at all.
        #expect(FamilySizes.render(MeetingPreview(), at: size).fittingSize.width > 0)
        #expect(FamilySizes.render(MeetingLayout(live: MeetingLive(zoomRunning: true), lines: [], past: MeetingSample.past), at: size).fittingSize.width > 0)
        #expect(FamilySizes.render(MeetingLayout(live: MeetingLive(), lines: [], past: []), at: size).fittingSize.width > 0)
    }

    @Test func samplesFillEveryFamily() {
        #expect(MeetingSample.past.count >= 3)
        #expect(MeetingSample.past.allSatisfy { !$0.summary.isEmpty && !$0.actionItems.isEmpty })
        #expect(MeetingSample.startedAt < .now)
        #expect(MeetingDigest(MeetingRecord(title: "t")).title == "t")
    }
}
