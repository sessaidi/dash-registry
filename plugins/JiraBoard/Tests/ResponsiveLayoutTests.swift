import AppKit
import DashKit
import DashKitUI
import SwiftUI
import Testing

/// The board draws a layout per size family, from sample tickets, in the widget and its preview.
@MainActor
struct ResponsiveLayoutTests {
    /// A content area in each family.
    static let sizes: [(WidgetLayout.Family, CGSize)] = [
        (.narrow, CGSize(width: 260, height: 180)),
        (.medium, CGSize(width: 440, height: 300)),
        (.wide, CGSize(width: 720, height: 300)),
        (.large, CGSize(width: 880, height: 480)),
    ]

    @Test func eachFamilyBuildsFromTheSamples() {
        for (family, size) in Self.sizes {
            #expect(WidgetLayout.family(for: size) == family)
            for mode in ["board", "followed"] {
                let config = JiraBoardWidget.Config(mode: mode, hideDone: false)
                let tickets = JiraTicket.visible(JiraTicket.samples, config: config)
                let columns = mode == "board" ? JiraClient.Column.samples : JiraBoardLayout.statusColumns(tickets)
                let view = JiraBoardContent(config: config, tickets: tickets, columns: columns, onSelect: { _ in })
                    .environment(\.jiraSelectedKey, tickets.first?.key)
                    .environment(\.widgetLayout, WidgetLayout(size: size))
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width > 0, "\(family) \(mode) has content")
            }
            let preview = NSHostingView(rootView: JiraBoardWidget.preview(config: JiraBoardWidget.defaultConfig)
                .environment(\.widgetLayout, WidgetLayout(size: size)).frame(width: size.width, height: size.height))
            preview.frame = CGRect(origin: .zero, size: size)
            preview.layoutSubtreeIfNeeded()
        }
    }

    @Test func narrowCountsTheUsersWorkInProgress() {
        let followed = JiraTicket.visible(JiraTicket.samples, config: JiraBoardWidget.Config(mode: "followed", hideDone: false))
        let mine = JiraBoardContent.inProgress(followed)
        #expect(mine.mine && mine.tickets.map(\.key) == ["WEB-475", "WEB-488", "WEB-466", "OPS-212"])
        // Nobody followed among the shown tickets: every ticket in progress counts.
        let others = JiraTicket.samples.filter { !$0.followed }
        let all = JiraBoardContent.inProgress(others)
        #expect(!all.mine && all.tickets.map(\.key) == ["WEB-471"])
        #expect(JiraBoardContent.tone("done") == .success && JiraBoardContent.tone("new") == .neutral)
    }
}
