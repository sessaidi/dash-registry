import DashKitUI
import SwiftUI
import Testing

/// Every size family renders the sample containers (the gallery shows each).
@MainActor
struct ContainersLayoutTests {
    static let sizes: [WidgetLayout.Family: CGSize] = [
        .narrow: CGSize(width: 280, height: 260), .medium: CGSize(width: 480, height: 320),
        .wide: CGSize(width: 720, height: 300), .large: CGSize(width: 720, height: 480),
    ]

    @Test(arguments: WidgetLayout.Family.allCases)
    func rendersEachFamily(_ family: WidgetLayout.Family) throws {
        let size = try #require(Self.sizes[family])
        #expect(WidgetLayout.family(for: size) == family)
        let view = ContainersContent(containers: DockerContainer.samples, total: 10, queryText: "state = 'running'", error: "socket timed out")
            .frame(width: size.width, height: size.height)
            .environment(\.widgetLayout, WidgetLayout(size: size))
        #expect(ImageRenderer(content: view).nsImage != nil)
    }

    @Test func samplesCoverEveryTone() {
        let tones = Set(DockerContainer.samples.map(\.tone))
        #expect(tones.isSuperset(of: [.success, .danger, .warning, .info, .neutral]))
        #expect(DockerContainer.samples.count(where: \.needsAttention) == 3)
    }

    @Test func statusDetailDropsStateAndHealth() {
        #expect(DockerContainer(id: "1", name: "a", image: "i", state: "running", status: "Up 3 hours (healthy)").statusDetail == "3 hours")
        #expect(DockerContainer(id: "1", name: "a", image: "i", state: "exited", status: "Exited (1) 2 minutes ago").statusDetail == "2 minutes ago")
    }
}
