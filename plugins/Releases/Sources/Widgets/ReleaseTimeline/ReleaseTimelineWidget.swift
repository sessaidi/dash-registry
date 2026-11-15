import DashKit
import DashKitUI
import SwiftUI

/// Release timeline: releases from git tags as eras on one lane per train, with builds, hotfixes,
/// today and an events lane. It observes `ReleasesFeature`, whose poller keeps the timelines fresh.
struct ReleaseTimelineWidget: DashboardWidget {
    /// Everything here is chosen in the widget's settings; the widget itself only shows it.
    struct Config: Codable, Equatable, Sendable {
        /// A repository id; nil shows every configured repository, one group of lanes each.
        var repository: String?
        /// Days shown when the widget opens; nil is everything.
        var period: Int? = 90
        /// One train (lowercased suffix, "" for the shared one); nil is every train.
        var train: String?
        /// Show the launches/incidents lane.
        var events: Bool = true
    }

    static let kind = "releases.timeline"
    static let displayName = "Release timeline"
    static let summary = "Releases from git tags as eras on one lane per train, with build ticks, hotfixes, today and an events lane. Pinch or scroll to zoom, drag to pan, search a ticket, text or date, click a release for its builds, commits and tickets. Repository (a checkout or one from GitHub/GitLab), period, train and how often to check for changes are set in the widget's settings."
    static let systemImage = "point.bottomleft.forward.to.point.topright.scurvepath"
    static let defaultSize = WidgetSize.wide
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "repository": ["type": "string", "description": "Repository id from Settings › Releases; omit for every repository."],
            "period": ["type": "integer", "description": "Days shown at first (30, 90, 180, 365); omit for all."],
            "train": ["type": "string", "description": "Only this train (eu, us…; \"\" for the shared one); omit for all."],
            "events": ["type": "boolean", "description": "Show the launches/incidents/milestones lane."],
        ],
    ]

    static let actions = [
        WidgetAction(name: "search", description: "Search the timeline like the magnifier: a ticket key or text highlights matching releases and fits them; a date (2026-10-12, 12 Oct, W41) jumps there and marks the release live that day.",
                     properties: ["text": JSONSchema.string("Ticket, text or date.")], required: ["text"]),
        WidgetAction(name: "select_release", description: "Select a release by name, short name or build tag and open its detail (builds, commits, tickets); linked widgets follow the selection.",
                     properties: ["name": JSONSchema.string("e.g. release-2026W41-03-eu, W41-03-eu or a build tag.")], required: ["name"]),
        WidgetAction(name: "set_train", description: "Show one train, or all. Temporary: the widget's saved train stays.",
                     properties: ["train": JSONSchema.string("eu, us… ; \"shared\" for the shared one; \"all\" for every train.")], required: ["train"]),
        WidgetAction(name: "set_period", description: "Show the last N days (30, 90, 180, 365); omit days for everything. Temporary: the widget's saved period stays.",
                     properties: ["days": JSONSchema.integer("Days, or omit for all.")]),
        WidgetAction(name: "zoom", description: "Show exactly this date range.",
                     properties: ["from": JSONSchema.string("Start date."), "to": JSONSchema.string("End date.")], required: ["from", "to"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected release."),
        WidgetAction(name: "clear", description: "Stop searching, close the detail and drop Dashii's temporary train and period (back to the widget's settings)."),
    ]

    static let queryFields = Release.queryFields

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        if let feature = context.host.ext(ReleasesFeature.self) {
            ReleaseTimelineView(feature: feature, host: context.host, config: config,
                                widgetQuery: context.query(fields: Release.queryFields), queryText: context.queryText)
        } else {
            StateView(.failed(message: "Releases isn't loaded."))
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        ReleaseTimelineSettings(feature: context.host.ext(ReleasesFeature.self), host: context.host, config: config)
    }

    /// Sample releases for the widget gallery (never git).
    static func preview(config: Config) -> some View {
        let timeline = ReleaseSamples.timeline
        return TimelineChart(model: TimelineModel(timelines: [timeline], events: ReleaseSamples.events, train: nil, showEvents: true),
                             domain: ReleaseSamples.now.addingTimeInterval(-75 * 86_400)...ReleaseSamples.now.addingTimeInterval(3 * 86_400),
                             now: ReleaseSamples.now, compact: false, selected: nil, hovered: nil, query: "")
            .frame(height: 150)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(ReleasesFeature.self) else { return .null }
        let since = config.period.map { Date.now.addingTimeInterval(-Double($0) * 86_400) }
        return .array(feature.repositories.filter { config.repository == nil || $0.id == config.repository }.compactMap { repository in
            guard let timeline = feature.timelines[repository.id] else { return nil }
            let releases = timeline.releases.filter { release in
                (config.train == nil || release.train == config.train) && (since.map { release.end >= $0 } ?? true)
            }
            return ["repo": .string(repository.name),
                    "explanation": """
                        Each release (a tag without its build number) is an era on its train's lane, from its first build until \
                        the next release on that train replaced it (ended_by next), the train went quiet (idle) or another train \
                        took over (handover). Builds are the tags of one release; a hotfix is a build cut off the default branch \
                        (a cherry-pick). new_commits are the commits since the release live before it; tickets are the Jira keys \
                        in them. live_now is what is deployed on each train today.
                        """,
                    "live_now": .array(timeline.liveAt(.now).map { ["train": .string(timeline.trainTitle($0.train)), "tag": .string($0.build.tag)] }),
                    "releases": .array(releases.reversed().prefix(60).map { ReleasesFeature.summary($0, timeline) })]
        })
    }
}

/// Repository, period, train and events lane.
private struct ReleaseTimelineSettings: View {
    let feature: ReleasesFeature?
    let host: any ExtensionContext
    @Binding var config: ReleaseTimelineWidget.Config

    var body: some View {
        Section("Source") {
            if let feature {
                RepositoryPicker(feature: feature, host: host, selection: $config.repository)
            }
            Picker("Train", selection: $config.train) {
                Text("All trains").tag(String?.none)
                ForEach(trains, id: \.self) { train in
                    Text(RepositoryTimeline.trainTitle(train, among: trains)).tag(String?.some(train))
                }
            }
            if let feature, !shown.isEmpty {
                Picker("Check for changes", selection: Binding(
                    get: { shown.first?.refreshMinutes ?? 10 },
                    set: { minutes in
                        for index in feature.repositories.indices where shown.contains(where: { $0.id == feature.repositories[index].id }) {
                            feature.repositories[index].refreshMinutes = minutes
                        }
                    })) {
                    ForEach([1, 5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text(minutes == 1 ? "Every minute" : minutes == 60 ? "Every hour" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
            }
        }
        Section("View") {
            Picker("Period", selection: $config.period) {
                Text("All").tag(Int?.none)
                ForEach([365, 180, 90, 30], id: \.self) { Text("Last \($0) days").tag(Int?.some($0)) }
            }
            Toggle("Events lane (launches, incidents, milestones)", isOn: $config.events)
        }
    }

    /// The repositories this widget shows.
    private var shown: [RepositoryConfig] {
        (feature?.repositories ?? []).filter { config.repository == nil || $0.id == config.repository }
    }

    /// Trains of the chosen repositories.
    private var trains: [String] {
        var trains: [String] = []
        for timeline in feature?.timelines.values.sorted(by: { $0.repository.name < $1.repository.name }) ?? []
        where config.repository == nil || timeline.repository.id == config.repository {
            for train in timeline.trains where !trains.contains(train) { trains.append(train) }
        }
        if let train = config.train, !trains.contains(train) { trains.append(train) }
        return trains
    }
}
