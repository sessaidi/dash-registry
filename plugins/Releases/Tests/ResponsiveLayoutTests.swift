import AppKit
import DashKit
import DashKitUI
import SwiftUI
import Testing

/// The release timeline draws a layout per size family from its gallery samples.
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

    /// Lays `view` out at the family's size in a window, so its body (and every subview's) runs.
    /// With TEST_RUNNER_DASH_RESPONSIVE_RENDER=<folder>, also writes it there as <name>-<family>.png.
    @discardableResult
    static func render(_ view: some View, _ family: WidgetLayout.Family, name: String? = nil) -> NSView {
        let size = size(family)
        #expect(WidgetLayout(size: size).family == family)
        let frame = CGRect(origin: .zero, size: CGSize(width: size.width + 24, height: size.height + 24))
        let host = NSHostingView(rootView: view.environment(\.widgetLayout, WidgetLayout(size: size))
            .padding(12).frame(width: frame.width, height: frame.height).background(Color.white).environment(\.colorScheme, .light))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
    func timelineBuildsForEachFamily(_ family: WidgetLayout.Family) {
        let host = Self.render(ReleaseTimelineWidget.preview(config: ReleaseTimelineWidget.defaultConfig), family, name: "releases")
        #expect(host.fittingSize.width > 0)
        Self.render(ReleaseTimelineWidget.preview(config: .init(train: "eu", events: false)), family, name: "releases-eu")
    }

    @Test func samplesLookReal() throws {
        let feature = ReleaseSamples.feature
        #expect(feature.repositories.map(\.id) == ["sample"])
        #expect(feature.now() == ReleaseSamples.now)
        let timeline = try #require(feature.timelines["sample"])
        #expect(timeline.releases.allSatisfy { !$0.newCommits.isEmpty && !$0.tickets.isEmpty })
        // The us train's commits name PPT tickets, the others LAF.
        #expect(timeline.releases(on: "us").allSatisfy { $0.tickets.allSatisfy { $0.hasPrefix("PPT-") } })
    }

    @Test func glanceHeadlineIsTheNewestLiveRelease() throws {
        let timeline = ReleaseSamples.timeline
        let now = ReleaseSamples.now
        let live = timeline.liveAt(now).map { live in
            ReleaseTimelineView.Live(id: live.train, train: timeline.trainTitle(live.train), name: live.release.shortName, tag: live.build.tag,
                                     hotfix: !live.build.onBase, release: live.release, since: live.build.date)
        }
        let newest = try #require(live.max { $0.since < $1.since })
        let headline = ReleaseGlanceText.headline(live, now: now)
        #expect(headline.title == "\(newest.name) live")
        #expect(headline.detail.hasSuffix("\(live.count) trains live"))
        #expect(ReleaseGlanceText.headline([], now: now).title == "Nothing live")
    }
}
