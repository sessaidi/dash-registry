import Foundation

/// Gallery data: two trains splitting off a shared one, with a hotfix and a few events.
enum ReleaseSamples {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static var timeline: RepositoryTimeline {
        var tags: [TagInfo] = []
        for week in 0..<8 {
            let day = now.addingTimeInterval(Double(week - 9) * 7 * 86_400)
            tags.append(TagInfo(name: "release-2026W\(20 + week)-02-eu.01", date: day, commit: "e\(week)", subject: "LAF-\(100 + week): change"))
            tags.append(TagInfo(name: "release-2026W\(20 + week)-03-us.01", date: day.addingTimeInterval(86_400), commit: "u\(week)", subject: "PPT-\(200 + week): change"))
            if week % 3 == 1 {
                tags.append(TagInfo(name: "release-2026W\(20 + week)-02-eu.02", date: day.addingTimeInterval(2 * 86_400), commit: "e\(week)b", subject: "fix"))
            }
        }
        for week in 0..<4 {
            tags.append(TagInfo(name: "release-2026W\(14 + week)-02.01", date: now.addingTimeInterval(Double(week - 14) * 7 * 86_400), commit: "s\(week)", subject: "change"))
        }
        let repository = RepositoryConfig(id: "sample", name: "api", path: "/tmp")
        var timeline = ReleaseGrouping.timeline(tags, repository: repository, onBase: Set(tags.map(\.name)).subtracting(["release-2026W24-02-eu.02"]), now: now)
        // What each release shipped: a few commits with tickets, by a few people.
        let authors = ["ada", "sam", "jrivera", "sadik"]
        let changes = ["retry the order fetcher", "renewals banner", "faster EPG paging", "fix the login redirect", "cache channel art",
                       "drop the v1 search", "trace checkout calls", "bump the player SDK"]
        for index in timeline.releases.indices {
            let release = timeline.releases[index]
            let project = release.train == "us" ? "PPT" : "LAF"
            timeline.releases[index].commits = (0..<(3 + index % 6)).map { number in
                ReleaseCommit(sha: String(format: "%07x%02d", index * 4_099 + number * 131, number), author: authors[(index + number) % authors.count],
                              date: release.start.addingTimeInterval(-Double(number + 1) * 7_200),
                              subject: "\(project)-\(5_600 + index * 7 + number): \(changes[(index + number) % changes.count])",
                              alreadyShipped: false, build: release.builds[0].tag)
            }
        }
        return timeline
    }

    /// A feature showing the sample timeline and events, never reading git or saving settings:
    /// the gallery draws the widget's own view from it.
    @MainActor static let feature: ReleasesFeature = {
        let suite = "dev.sessaidi.Dash.releases.gallery-sample"
        let defaults = UserDefaults(suiteName: suite)!
        let feature = ReleasesFeature(defaults: defaults, cacheFile: nil)
        feature.showSample(timeline, events: events, now: now)
        defaults.removePersistentDomain(forName: suite)
        return feature
    }()

    static var events: [ReleaseEvent] {
        [ReleaseEvent(date: now.addingTimeInterval(-40 * 86_400), kind: .launch, title: "Web launch"),
         ReleaseEvent(date: now.addingTimeInterval(-22 * 86_400), kind: .incident, title: "Pods crash-loop"),
         ReleaseEvent(date: now.addingTimeInterval(-60 * 86_400), kind: .milestone, title: "Train split")]
    }
}
