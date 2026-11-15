import AppKit
import DashKit
import DashKitUI
import SwiftUI
import Testing

/// The widget draws a layout per size family, from the gallery's preset sizes, with sample data.
@MainActor
struct ResponsiveLayoutTests {
    /// A content area in each family.
    static let presets: [(WidgetLayout.Family, CGSize)] = [
        (.narrow, CGSize(width: 260, height: 180)),
        (.medium, CGSize(width: 440, height: 300)),
        (.wide, CGSize(width: 720, height: 300)),
        (.large, CGSize(width: 880, height: 480)),
    ]

    @Test func eachFamilyBuildsFromTheSamples() throws {
        let pulls = PullRequestSamples.pulls()
        let reviews = Dictionary(PullRequestSamples.reviews().map { ($0.prUID, $0) }, uniquingKeysWith: { first, _ in first })
        for (family, size) in Self.presets {
            #expect(WidgetLayout.family(for: size) == family)
            let view = PullRequestsContent(pulls: pulls, reviews: reviews, selectedUID: pulls[1].uid, onSelect: { _ in })
                .environment(\.widgetLayout, WidgetLayout(size: size))
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0, "\(family) has content")
            // The preview is the same responsive view.
            let preview = NSHostingView(rootView: PullRequestsWidget.preview(config: PullRequestsWidget.defaultConfig)
                .environment(\.widgetLayout, WidgetLayout(size: size)).frame(width: size.width, height: size.height))
            preview.frame = CGRect(origin: .zero, size: size)
            preview.layoutSubtreeIfNeeded()
        }
    }

    @Test func groupsPutWhatWaitsOnTheUserFirst() {
        let ordered = PullRequestGroup.ordered(PullRequestSamples.pulls())
        #expect(ordered.prefix(4).allSatisfy { $0.reviewRequested })
        #expect(ordered.dropFirst(4).prefix(2).allSatisfy { $0.isMine })
        #expect(ordered.count == 9)
    }
}
