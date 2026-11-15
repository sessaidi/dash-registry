import DashKit
import Foundation

/// Releases for DashQL: the `releases` and `builds` datasets (the timelines Dash has loaded) and
/// the timeline widget's query bar, which keeps the releases it matches on the chart.
extension Release {
    static let queryFields: [QueryDataset.Field] = [
        .init("id", "string", "repository|name"),
        .init("repo", "string", "Repository name", aliases: ["repository"]),
        .init("name", "string", "Release tag without the build number, e.g. release-2026W43-05-eu", aliases: ["release"]),
        .init("short", "string", "Short name, e.g. W43-05-eu"),
        .init("train", "string", "Train (eu, us…; empty for shared)"),
        .init("start", "date", "First build"),
        .init("end", "date", "When the next release replaced it (or it went quiet)"),
        .init("live", "bool", "Still the train's live release", aliases: ["current"]),
        .init("end_reason", "string", "next, idle, handover or today"),
        .init("days", "number", "How long it was live"),
        .init("builds", "number", "Builds (tags) of this release"),
        .init("last_build", "string", "Latest build tag"),
        .init("hotfix", "bool", "A build was cut off the default branch"),
        .init("tickets", "list", "Jira keys in the commits it brought (joins jira.key)", aliases: ["ticket"]),
        .init("authors", "list", "Who wrote the commits it brought"),
        .init("new_commits", "number", "Commits it brought"),
        .init("subjects", "list", "Subjects of the commits it brought"),
    ]

    func queryRow(repository: String) -> JSONValue {
        [
            "id": .string(id), "repo": .string(repository), "name": .string(name), "short": .string(shortName), "train": .string(train),
            "start": start.queryValue, "end": isCurrent ? .null : end.queryValue, "live": .bool(isCurrent),
            "end_reason": .string(endReason.rawValue), "days": .number((days * 10).rounded() / 10),
            "builds": .number(Double(builds.count)), "last_build": .string(lastBuild.tag), "hotfix": .bool(isHotfix),
            "tickets": .array(tickets.map(JSONValue.string)), "authors": .array(authors.map(JSONValue.string)),
            "new_commits": .number(Double(newCommits.count)), "subjects": .array(newCommits.map { .string($0.subject) }),
        ]
    }
}

extension Build {
    static let queryFields: [QueryDataset.Field] = [
        .init("tag", "string", "Build tag"),
        .init("release", "string", "Its release"),
        .init("repo", "string", "Repository name"),
        .init("train", "string", "Train"),
        .init("number", "number", "Build number"),
        .init("date", "date", "Tagged"),
        .init("commit", "string", "Tagged commit"),
        .init("subject", "string", "The commit's subject"),
        .init("hotfix", "bool", "Cut off the default branch"),
    ]

    func queryRow(release: Release, repository: String) -> JSONValue {
        [
            "tag": .string(tag), "release": .string(release.name), "repo": .string(repository), "train": .string(release.train),
            "number": number.map { .number(Double($0)) } ?? .null, "date": date.queryValue, "commit": .string(commit),
            "subject": .string(subject), "hotfix": .bool(!onBase),
        ]
    }
}

extension TimelineModel {
    /// The model with only the releases whose ids are in `keep` (events stay).
    func keeping(_ keep: Set<String>) -> TimelineModel {
        var model = self
        model.lanes = lanes.compactMap { lane in
            guard case .train = lane.kind else { return lane }
            let releases = lane.releases.filter { keep.contains($0.id) }
            guard !releases.isEmpty else { return nil }
            var kept = Lane(id: lane.id, kind: lane.kind, title: lane.title, subtitle: lane.subtitle, color: lane.color, releases: releases, events: lane.events)
            kept.groupTitle = lane.groupTitle
            return kept
        }
        return model
    }
}

extension ReleasesFeature {
    var datasets: [QueryDataset] {
        [
            QueryDataset(name: "releases", aliases: ["trains"], summary: "Releases of the repositories set up in Releases (trains, eras, builds, the tickets and commits each brought).",
                         fields: Release.queryFields) { [weak self] _ in
                guard let self else { return [] }
                return timelines.values.flatMap { timeline in timeline.releases.map { $0.queryRow(repository: timeline.repository.name) } }
            },
            QueryDataset(name: "builds", aliases: ["tags"], summary: "Release build tags, one row per tag.", fields: Build.queryFields) { [weak self] _ in
                guard let self else { return [] }
                return timelines.values.flatMap { timeline in
                    timeline.releases.flatMap { release in release.builds.map { $0.queryRow(release: release, repository: timeline.repository.name) } }
                }
            },
        ]
    }
}
