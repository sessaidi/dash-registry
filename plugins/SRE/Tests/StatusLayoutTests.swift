import DashKitUI
import SwiftUI
import Testing

/// Every size family renders the sample status (the gallery shows each).
@MainActor
struct StatusLayoutTests {
    static let sizes: [WidgetLayout.Family: CGSize] = [
        .narrow: CGSize(width: 280, height: 260), .medium: CGSize(width: 480, height: 320),
        .wide: CGSize(width: 720, height: 300), .large: CGSize(width: 720, height: 480),
    ]

    @Test(arguments: WidgetLayout.Family.allCases)
    func rendersEachFamily(_ family: WidgetLayout.Family) throws {
        let size = try #require(Self.sizes[family])
        #expect(WidgetLayout.family(for: size) == family)
        for snapshot in [StatusSnapshot.sample, StatusSnapshot(signals: Signals(sources: ["datadog"]), lastReport: nil)] {
            let renderer = ImageRenderer(content: StatusView(snapshot: snapshot, family: family, ask: { _ in }).frame(width: size.width, height: size.height))
            #expect(renderer.nsImage != nil)
        }
    }

    @Test func headlineCounts() {
        #expect(StatusSnapshot.sample.countLine == "3 critical · 3 warning")
        #expect(StatusSnapshot.sample.tone == .danger)
    }
}
