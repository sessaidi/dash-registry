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
        return ReleaseGrouping.timeline(tags, repository: repository, onBase: Set(tags.map(\.name)).subtracting(["release-2026W24-02-eu.02"]), now: now)
    }

    static var events: [ReleaseEvent] {
        [ReleaseEvent(date: now.addingTimeInterval(-40 * 86_400), kind: .launch, title: "Web launch"),
         ReleaseEvent(date: now.addingTimeInterval(-22 * 86_400), kind: .incident, title: "Pods crash-loop"),
         ReleaseEvent(date: now.addingTimeInterval(-60 * 86_400), kind: .milestone, title: "Train split")]
    }
}
