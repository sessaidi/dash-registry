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

@Suite("Backend Meeting widget layouts")
@MainActor
struct BackendMeetingLayoutTests {
    @Test(arguments: FamilySizes.all.map(\.0))
    func buildsForEachFamily(_ family: WidgetLayout.Family) {
        let size = FamilySizes.size(family)
        #expect(WidgetLayout.family(for: size) == family)
        #expect(FamilySizes.render(BackendMeetingWidget.preview(config: .init()), at: size).fittingSize.width > 0)
        // No report yet, and one being written.
        let config = Binding.constant(BackendMeetingWidget.Config())
        #expect(FamilySizes.render(BackendMeetingLayout(reports: [], config: config), at: size).fittingSize.width > 0)
        #expect(FamilySizes.render(BackendMeetingLayout(reports: [], progress: "Writing the report…", config: config), at: size).fittingSize.width > 0)
    }

    @Test func sectionsSplitThemesAndItems() {
        let sections = ReportSection.sections("- **A**: one\n- **In chantier**:\n  - x\n  - y\n\n- **Debug & Fix**\n- plain")
        #expect(sections == [
            ReportSection(title: "A", summary: "one", items: []),
            ReportSection(title: "In chantier", summary: "", items: ["x", "y"]),
            ReportSection(title: "Debug & Fix", summary: "", items: []),
            ReportSection(title: "plain", summary: "", items: []),
        ])
        #expect(ReportDigest.samples.first?.sections.count == 5)
    }
}
