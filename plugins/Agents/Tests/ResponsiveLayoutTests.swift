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

    /// Lays `view` out at `size` with that size's widget layout, as the dashboard does.
    @MainActor
    static func render(_ view: some View, at size: CGSize) -> NSView {
        let host = NSHostingView(rootView: view.environment(\.widgetLayout, WidgetLayout(size: size)).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }
}

@Suite("Agents widget layouts")
@MainActor
struct AgentsLayoutTests {
    @Test(arguments: FamilySizes.all.map(\.0))
    func buildsForEachFamily(_ family: WidgetLayout.Family) {
        let size = FamilySizes.all.first { $0.0 == family }!.1
        #expect(WidgetLayout.family(for: size) == family)
        let samples = FamilySizes.render(AgentsLayout(rows: AgentSummary.samples, open: { _ in }), at: size)
        #expect(samples.fittingSize.width > 0)
        let empty = FamilySizes.render(AgentsLayout(rows: [], open: { _ in }, start: { _ in }), at: size)
        #expect(empty.fittingSize.width > 0)
        _ = AgentsWidget.preview(config: AgentsWidget.defaultConfig)
    }

    @Test func headlineSaysWhatNeedsYou() {
        #expect(AgentSummary.headline(AgentSummary.samples) == "2 working · 2 need you")
        #expect(AgentSummary.headline([]) == "No agents")
        let ordered = AgentSummary.byAttention(AgentSummary.samples)
        #expect(ordered.first?.status == "failed")
        #expect(ordered.last?.hasPullRequest == true)
    }
}
