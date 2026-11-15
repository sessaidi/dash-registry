import DashKit
import Foundation

/// Releases for Dashii: list releases, one release's detail, what was live when, which release
/// shipped a change, and events for the timeline's events lane.
extension ReleasesFeature {
    private struct ListInput: Decodable { let repo: String?; let train: String?; let since: String? }
    private struct TagInput: Decodable { let tag: String; let repo: String? }
    private struct DateInput: Decodable { let date: String; let repo: String? }
    private struct TextInput: Decodable { let text: String; let repo: String? }
    private struct EventInput: Decodable { let date: String; let title: String; let kind: String?; let note: String?; let repo: String? }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "releases_list",
                description: "List releases from git tags in the repositories set up in Releases: name, train, first and last build, how long it was live and why it ended, hotfix, commit and ticket counts. Newest first.",
                properties: [
                    "repo": JSONSchema.string("Repository name (omit for every configured one)."),
                    "train": JSONSchema.string("Train, e.g. eu or us; \"shared\" for tags without a train suffix."),
                    "since": JSONSchema.string("Only releases live on or after this date (YYYY-MM-DD)."),
                ]) { [weak self] input in
                guard let self else { return .null }
                let input = try input.toolInput(ListInput.self)
                let since = try input.since.map { try self.date($0) }
                var out: [JSONValue] = []
                for repository in try repositories(input.repo) {
                    let timeline = try await timeline(repository)
                    let train = input.train.map { $0.lowercased() == "shared" ? "" : $0.lowercased() }
                    let releases = timeline.releases.filter { release in
                        (train == nil || release.train == train) && (since.map { release.end >= $0 } ?? true)
                    }
                    out.append(["repo": .string(repository.name), "base_branch": .string(timeline.baseBranch),
                                "trains": .array(timeline.trains.map { .string(timeline.trainTitle($0)) }),
                                "releases": .array(releases.reversed().prefix(200).map { Self.summary($0, timeline) })])
                }
                return .array(out)
            },
            DashiiTool(
                name: "release_detail",
                description: "One release by tag (any build tag or the release name): builds with dates and commits, live period, previous and next release, hotfix status, the commits it brought grouped by ticket project (changes the previous release already shipped as a cherry-pick are flagged), tickets and authors.",
                properties: ["tag": JSONSchema.string("e.g. release-2026W23-02-eu.01 or v1.4.0."), "repo": JSONSchema.string("Repository name (optional).")],
                required: ["tag"]) { [weak self] input in
                guard let self else { return .null }
                let input = try input.toolInput(TagInput.self)
                for repository in try repositories(input.repo) {
                    let timeline = try await timeline(repository)
                    if let release = timeline.release(named: input.tag) { return Self.detail(release, timeline) }
                }
                throw ToolError("No release tag \(input.tag).")
            },
            DashiiTool(
                name: "release_live_at",
                description: "Which tag each train had in production at a moment: its last release tag before then, with the release it belongs to.",
                properties: ["date": JSONSchema.string("YYYY-MM-DD (the end of that day; today means now) or an ISO 8601 time."),
                             "repo": JSONSchema.string("Repository name (omit for every configured one).")],
                required: ["date"]) { [weak self] input in
                guard let self else { return .null }
                let input = try input.toolInput(DateInput.self)
                let date = try self.date(input.date)
                var out: [JSONValue] = []
                for repository in try repositories(input.repo) {
                    let timeline = try await timeline(repository)
                    out.append(["repo": .string(repository.name), "at": .string(date.formatted(.iso8601)),
                                "live": .array(timeline.liveAt(date).map { live in
                                    ["train": .string(timeline.trainTitle(live.train)), "tag": .string(live.build.tag),
                                     "tagged": .string(live.build.date.formatted(.iso8601)), "release": .string(live.release.name),
                                     "hotfix": .bool(!live.build.onBase)]
                                })])
                }
                return .array(out)
            },
            DashiiTool(
                name: "releases_containing",
                description: "Which release first shipped a change, on each train: give a ticket key (KAN-5917), a commit sha (at least 7 characters) or words from a commit subject.",
                properties: ["text": JSONSchema.string("Ticket key, commit sha or text."), "repo": JSONSchema.string("Repository name (optional).")],
                required: ["text"]) { [weak self] input in
                guard let self else { return .null }
                let input = try input.toolInput(TextInput.self)
                var out: [JSONValue] = []
                for repository in try repositories(input.repo) {
                    let timeline = try await timeline(repository)
                    let hits = try await Self.containing(input.text, in: timeline)
                    out.append(["repo": .string(repository.name),
                                "first_shipped": .array(hits.map { hit in
                                    ["train": .string(timeline.trainTitle(hit.train)), "release": .string(hit.release.name),
                                     "first_build": .string(hit.release.builds.first?.tag ?? ""),
                                     "tagged": .string(hit.release.start.formatted(.iso8601)),
                                     "commit": hit.commit.map { ["sha": .string($0.shortSHA), "subject": .string($0.subject), "build": .string($0.build)] } ?? .null]
                                })])
                }
                return .array(out)
            },
            DashiiTool(
                name: "release_events_add",
                description: "Add a launch, incident or milestone to the Releases timeline's events lane (stored locally in Dash).",
                properties: [
                    "date": JSONSchema.string("YYYY-MM-DD."),
                    "title": JSONSchema.string("Short title."),
                    "kind": JSONSchema.string("Kind of event.", enum: ReleaseEvent.Kind.allCases.map(\.rawValue)),
                    "note": JSONSchema.string("Optional details: severity, ticket, link."),
                    "repo": JSONSchema.string("Repository it concerns (omit for every repository)."),
                ],
                required: ["date", "title"], requiresApproval: true) { [weak self] input in
                guard let self else { return .null }
                let input = try input.toolInput(EventInput.self)
                guard let day = ReleaseDates.parse(input.date, now: .distantPast) else { throw ToolError("Unreadable date \(input.date); use YYYY-MM-DD.") }
                var kind = ReleaseEvent.Kind.milestone
                if let raw = input.kind {
                    guard let parsed = ReleaseEvent.Kind(rawValue: raw.lowercased()) else { throw ToolError("Kind is launch, incident or milestone.") }
                    kind = parsed
                }
                let repository = try input.repo.map { try repositories($0)[0].id }
                // Noon of that day, so it sits mid-day on the lane.
                let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
                let event = ReleaseEvent(date: noon, kind: kind, title: input.title, note: input.note ?? "", repository: repository)
                timelineEvents.append(event)
                return ["added": .string(event.id), "count": .number(Double(timelineEvents.count))]
            },
        ]
    }

    private func date(_ text: String) throws -> Date {
        guard let date = ReleaseDates.parse(text, now: now()) else { throw ToolError("Unreadable date \(text); use YYYY-MM-DD.") }
        return date
    }

    /// The range search, then (for a sha the ranges don't have) the first release whose head contains it.
    static func containing(_ text: String, in timeline: RepositoryTimeline) async throws -> [(train: String, release: Release, commit: ReleaseCommit?)] {
        var hits = timeline.firstContaining(text)
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !timeline.repository.isRemote, query.count >= 7, query.allSatisfy(\.isHexDigit) else { return hits }
        let git = GitReader(directory: timeline.repository.url)
        guard let commit = await git.resolve(query) else { return hits }
        for train in timeline.trains where !hits.contains(where: { $0.train == train }) {
            for release in timeline.releases(on: train) where await git.isAncestor(commit, of: release.lastBuild.commit) {
                hits.append((train, release, nil))
                break
            }
        }
        return hits
    }

    static func summary(_ release: Release, _ timeline: RepositoryTimeline) -> JSONValue {
        [
            "release": .string(release.name), "train": .string(timeline.trainTitle(release.train)),
            "builds": .array(release.builds.map { .string($0.tag) }),
            "first_build": .string(release.start.formatted(.iso8601)), "last_build": .string(release.lastBuild.date.formatted(.iso8601)),
            "live_until": release.isCurrent ? "today" : .string(release.end.formatted(.iso8601)), "ended_by": .string(release.endReason.rawValue),
            "live_days": .number((release.days * 10).rounded() / 10), "hotfix": .bool(release.isHotfix),
            "new_commits": .number(Double(release.newCommits.count)), "tickets": .number(Double(release.tickets.count)),
        ]
    }

    static func detail(_ release: Release, _ timeline: RepositoryTimeline) -> JSONValue {
        var json = summary(release, timeline).object ?? [:]
        json["repo"] = .string(timeline.repository.name)
        json["release_index"] = .string("\(release.index + 1) of \(release.trainCount)")
        json["previous"] = release.previous.map(JSONValue.string) ?? .null
        json["next"] = release.next.map(JSONValue.string) ?? .null
        json["compared_with"] = release.base.map(JSONValue.string) ?? .null
        json["builds"] = .array(release.builds.map { build in
            ["tag": .string(build.tag), "tagged": .string(build.date.formatted(.iso8601)), "commit": .string(build.shortCommit),
             "on_base_branch": .bool(build.onBase), "subject": .string(build.subject),
             "new_commits": .number(Double(release.newCommits.filter { $0.build == build.tag }.count))]
        })
        json["tickets"] = .array(release.tickets.map { .string($0) })
        json["authors"] = .array(release.authors.map { .string($0) })
        json["already_shipped"] = .number(Double(release.commits.count - release.newCommits.count))
        json["commits_truncated"] = .bool(release.commitsTruncated)
        json["commits"] = .array(CommitGroups.group(release.commits).map { group in
            ["group": .string(group.title), "commits": .array(group.commits.prefix(150).map { commit in
                ["sha": .string(commit.shortSHA), "subject": .string(commit.subject), "author": .string(commit.author),
                 "build": .string(commit.build), "already_shipped": .bool(commit.alreadyShipped)]
            })]
        })
        return .object(json)
    }
}
