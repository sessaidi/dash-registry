import AppKit
import DashKit
import DashKitUI
import SwiftUI
import Testing

/// Each widget draws a layout per size family from its gallery samples.
@MainActor
struct ResponsiveLayoutTests {
    /// A content size inside each family.
    static func size(_ family: WidgetLayout.Family) -> CGSize {
        switch family {
        case .narrow: CGSize(width: 272, height: 280)
        case .wide: CGSize(width: 760, height: 300)
        case .large: CGSize(width: 900, height: 560)
        default: CGSize(width: 480, height: 320)
        }
    }

    /// Lays `view` out at the family's size, so its body (and every subview's) runs. With
    /// TEST_RUNNER_DASH_RESPONSIVE_RENDER=<folder>, also writes it there as <name>-<family>.png.
    @discardableResult
    static func render(_ view: some View, _ family: WidgetLayout.Family, name: String? = nil) -> NSView {
        let size = size(family)
        #expect(WidgetLayout(size: size).family == family)
        let host = NSHostingView(rootView: view.environment(\.widgetLayout, WidgetLayout(size: size))
            .padding(12).frame(width: size.width + 24, height: size.height + 24).background(Color.white).environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: CGSize(width: size.width + 24, height: size.height + 24))
        // In a window, so lists and tables (AppKit-backed) lay out their rows too.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.2))
        host.display()
        if let name, let folder = ProcessInfo.processInfo.environment["DASH_RESPONSIVE_RENDER"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: folder).appending(path: "\(name)-\(family.rawValue).png"))
        }
        return host
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func workspacesBuildsForEachFamily(_ family: WidgetLayout.Family) {
        let host = Self.render(WorkspacesWidget.preview(config: .init(onlyMine: false)), family, name: "workspaces")
        #expect(host.fittingSize.width > 0)
        // Selected and empty states too.
        Self.render(WorkspaceListContent(scope: "dev/us", items: WorkspaceItem.samples, busy: [], isLoading: false, error: nil, selectedName: "papi-perf"), family, name: "workspaces-selected")
        Self.render(WorkspaceListContent(scope: "dev/us", items: [], busy: [], isLoading: false, error: "Can't reach the cluster"), family)
    }

    @Test(arguments: WidgetLayout.Family.allCases)
    func trainBuildsForEachFamily(_ family: WidgetLayout.Family) {
        let host = Self.render(DeploymentTrainWidget.preview(config: DeploymentTrainWidget.defaultConfig), family, name: "train")
        #expect(host.fittingSize.width > 0)
        Self.render(TrainContent(cars: TrainCar.samples, selectedID: "2"), family, name: "train-selected")
    }

    @Test func workspaceGlanceLeadsWithWhatNeedsAttention() {
        let items = WorkspaceItem.samples
        let headline = WorkspaceItem.headline(items, busy: ["checkout-flow"])
        #expect(headline.title == "9 workspaces")
        #expect(headline.detail == "1 working · 2 to clean · 2 persisted")
        let top = WorkspaceItem.mostImportant(items, busy: ["checkout-flow"]).map(\.name)
        #expect(top == ["checkout-flow", "old-search", "legacy-epg"])
        // Nothing busy or to clean: the most recently deployed.
        #expect(WorkspaceItem.mostImportant(items.filter { $0.cleanReason == nil }, busy: []).map(\.name) == ["epg-refresh", "checkout-flow", "search-v3"])
        #expect(WorkspaceItem.headline([], busy: []).detail == "All active")
    }

    @Test func trainGlanceLeadsWithFailures() {
        let cars = TrainCar.samples
        #expect(TrainCar.headline(cars).title == "1 workspace failing")
        #expect(TrainCar.headline(cars).tone == .danger)
        // Latest per workspace: ops-212 failed, laf-5680 deploying, then the most recent.
        #expect(TrainCar.mostImportant(cars).map(\.workspace) == ["ops-212", "laf-5680", "checkout-flow"])
        let green = cars.filter(\.succeeded)
        #expect(TrainCar.headline(green).title == "All green")
        #expect(TrainCar.latestPerWorkspace(cars).count == 4)
    }
}
