import DashKitUI
import SwiftUI
import Testing

/// Every size family renders the sample monitors, with and without a selection.
@MainActor
struct MonitorsLayoutTests {
    static let sizes: [WidgetLayout.Family: CGSize] = [
        .narrow: CGSize(width: 280, height: 260), .medium: CGSize(width: 480, height: 320),
        .wide: CGSize(width: 720, height: 300), .large: CGSize(width: 720, height: 480),
    ]

    @Test(arguments: WidgetLayout.Family.allCases)
    func rendersEachFamily(_ family: WidgetLayout.Family) throws {
        let size = try #require(Self.sizes[family])
        #expect(WidgetLayout.family(for: size) == family)
        for selected in [nil, 3] as [Int?] {
            let view = MonitorsContent(monitors: DatadogMonitor.sample, total: 9, queryText: "service = 'api'", selected: .constant(selected))
                .frame(width: size.width, height: size.height)
                .environment(\.widgetLayout, WidgetLayout(size: size))
            #expect(ImageRenderer(content: view).nsImage != nil)
        }
    }

    @Test func serviceTag() {
        #expect(DatadogMonitor.sample[0].tag("service") == "api")
        #expect(DatadogMonitor.sample[0].tag("missing") == nil)
        #expect(Set(DatadogMonitor.sample.map(\.chartStatus)) == ["Alert", "Warn", "No Data"])
    }
}
