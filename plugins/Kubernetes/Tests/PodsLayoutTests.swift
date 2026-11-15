import DashKitUI
import SwiftUI
import Testing

/// Every size family renders the sample pods (the gallery shows each), with and without a selection.
@MainActor
struct PodsLayoutTests {
    static let sizes: [WidgetLayout.Family: CGSize] = [
        .narrow: CGSize(width: 280, height: 260), .medium: CGSize(width: 480, height: 320),
        .wide: CGSize(width: 720, height: 300), .large: CGSize(width: 720, height: 480),
    ]

    @Test(arguments: WidgetLayout.Family.allCases)
    func rendersEachFamily(_ family: WidgetLayout.Family) throws {
        let size = try #require(Self.sizes[family])
        #expect(WidgetLayout.family(for: size) == family)
        for selected in [nil, "papi-eu/api-8b1e2f4c7-q4m8n"] as [String?] {
            let view = PodsContent(pods: PodsSamples.pods, total: 12, warnings: PodsSamples.warnings, scope: PodsSamples.scope)
                .frame(width: size.width, height: size.height)
                .environment(\.widgetLayout, WidgetLayout(size: size))
                .environment(\.podSelectedID, selected)
            #expect(ImageRenderer(content: view).nsImage != nil)
        }
        let empty = PodsContent(pods: [], total: 3, warnings: [:], scope: PodsSamples.scope, emptyTitle: "All pods healthy")
            .frame(width: size.width, height: size.height).environment(\.widgetLayout, WidgetLayout(size: size))
        #expect(ImageRenderer(content: empty).nsImage != nil)
    }

    @Test func countsLeadWithTheWorst() {
        let counts = PodCounts(PodsSamples.pods)
        #expect(counts.headline == "3 crash-looping")
        #expect(counts.headlineTone == .danger)
        #expect(counts.line == "4 running · 2 not ready · 1 done · ↻31")
        #expect(PodSummary.byUrgency(PodsSamples.pods).first?.name == "api-8b1e2f4c7-q4m8n")
        #expect(PodCounts(PodsSamples.pods.filter { $0.tone == .success }).headline == "4 healthy")
    }
}
