import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Release timelines read from git tags: in a local checkout with git, or, for a repository from
/// the GitHub or GitLab integration without a checkout, from the mirror the integration keeps in
/// Dash (online is the source of truth; the mirror is refreshed from it). Which release each train
/// had live when, what each one brought, and launches or incidents around them.
@MainActor
@Observable
final class ReleasesFeature: DashExtension {
    let id = "releases"
    let name = "Releases"
    let systemImage = "point.bottomleft.forward.to.point.topright.scurvepath"
    let metadata = ExtensionMetadata(
        version: "1.4.0", author: .dash,
        summary: "A release timeline from your repositories' git tags: trains, builds, hotfixes, what each release shipped and what was live when.",
        category: .sourceControl, tags: ["git", "releases", "timeline"], minimumDashKit: "1.5.0")

    /// How often the poller looks for repositories due a refresh (each has its own interval).
    static let tick: Duration = .seconds(60)
    /// A cached timeline younger than this answers tools without asking git again.
    static let freshness: TimeInterval = 120

    /// Configured in Settings › Releases; starts empty.
    var repositories: [RepositoryConfig] {
        didSet {
            save(repositories, "repositories")
            let ids = Set(repositories.map(\.id))
            timelines = timelines.filter { ids.contains($0.key) }
            errors = errors.filter { ids.contains($0.key) }
        }
    }
    /// Launches, incidents and milestones; edited in Settings or added by Claude.
    var timelineEvents: [ReleaseEvent] { didSet { save(timelineEvents, "events") } }

    private(set) var timelines: [String: RepositoryTimeline] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    private(set) var lastRefresh: Date?
    /// When each repository was last read (successfully or not), for its refresh interval.
    @ObservationIgnored private var attempted: [String: Date] = [:]

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let loader: ReleaseLoader
    /// Overridable "now", for tests.
    @ObservationIgnored var now: () -> Date = { .now }

    /// `cacheFile`: where commit ranges are kept between launches (nil keeps them in memory only).
    init(defaults: UserDefaults = DashStorage.defaults, cacheFile: URL? = ReleaseLoader.defaultCacheFile) {
        self.defaults = defaults
        loader = ReleaseLoader(cacheFile: cacheFile)
        // Repositories added while Releases kept bare clones are read from the mirror now.
        repositories = (Self.load([RepositoryConfig].self, "repositories", defaults) ?? []).map { repository in
            var repository = repository
            if repository.source != nil, repository.path.contains("releases-mirrors") { repository.path = "" }
            return repository
        }
        timelineEvents = Self.load([ReleaseEvent].self, "events", defaults) ?? []
    }

    var widgets: [WidgetType] { [WidgetType(ReleaseTimelineWidget.self)] }
    var events: [EventDefinition] { [EventDefinition("release.tagged", "A new release tag appeared in a repository set up in Releases.")] }

    func settingsView() -> AnyView { AnyView(ReleasesSettingsView(feature: self)) }

    func start(host: any ExtensionContext) {
        self.host = host
        poller?.cancel()
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "Dash/releases-mirrors"))
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    // MARK: Loading

    /// Reloads every repository (or one), keeping the last good timeline when reading fails.
    /// Remote repositories are synced from their service first.
    func refresh(_ only: String? = nil) async {
        for repository in repositories where only == nil || only == repository.id {
            await reload(repository, force: true)
        }
        lastRefresh = now()
    }

    /// Reloads the repositories whose refresh interval has passed.
    func refreshDue() async {
        for repository in repositories where now().timeIntervalSince(attempted[repository.id] ?? .distantPast) >= repository.refreshInterval {
            await reload(repository)
        }
        lastRefresh = now()
    }

    /// A remote repository is synced from its service when its mirror is older than its refresh
    /// interval, or always with `force`.
    private func reload(_ repository: RepositoryConfig, force: Bool = false) async {
        guard !loading.contains(repository.id) else { return }
        loading.insert(repository.id)
        attempted[repository.id] = now()
        defer { loading.remove(repository.id) }
        do {
            let source = repository.isRemote ? try await syncedSource(repository, force: force) : nil
            let timeline = try await loader.load(repository, now: now(), source: source)
            // The settings may have changed while git ran.
            guard repositories.first(where: { $0.id == repository.id }) == repository else { return }
            announceNewTags(old: timelines[repository.id], new: timeline)
            timelines[repository.id] = timeline
            errors[repository.id] = nil
        } catch {
            errors[repository.id] = error.localizedDescription
        }
    }

    private func announceNewTags(old: RepositoryTimeline?, new: RepositoryTimeline) {
        guard let old else { return }
        let known = Set(old.releases.flatMap(\.builds).map(\.tag))
        for release in new.releases {
            for build in release.builds where !known.contains(build.tag) {
                host?.emit("release.tagged", from: self, title: "\(new.repository.name): \(build.tag)",
                           detail: "\(new.trainTitle(release.train)) train · \(release.newCommits.count) new commits", importance: .info)
            }
        }
    }

    /// A timeline fresh enough to answer from, loading it if needed.
    func timeline(_ repository: RepositoryConfig) async throws -> RepositoryTimeline {
        if let cached = timelines[repository.id], now().timeIntervalSince(cached.loadedAt) < Self.freshness { return cached }
        await reload(repository)
        if let timeline = timelines[repository.id] { return timeline }
        throw ToolError(errors[repository.id] ?? "Couldn't read \(repository.name).")
    }

    /// Repositories a tool asks about: one by name, path or id, or every one when nil.
    func repositories(_ reference: String?) throws -> [RepositoryConfig] {
        guard !repositories.isEmpty else { throw ToolError("No repositories yet: add one in Settings › Releases.") }
        guard let reference = reference?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else { return repositories }
        let lowered = reference.lowercased()
        let expanded = (reference as NSString).expandingTildeInPath
        if let match = repositories.first(where: { $0.id == reference || $0.name.lowercased() == lowered || $0.url.path == expanded })
            ?? repositories.first(where: { $0.url.lastPathComponent.lowercased() == lowered }) {
            return [match]
        }
        throw ToolError("No repository \(reference). Configured: \(repositories.map(\.name).joined(separator: ", ")).")
    }

    /// Events for a repository (its own and the ones for every repository), oldest first.
    func events(for repository: String?) -> [ReleaseEvent] {
        timelineEvents.filter { $0.repository == nil || repository == nil || $0.repository == repository }.sorted { $0.date < $1.date }
    }

    /// Adds a checkout, guessing its tag scheme (release-* builds, else semver), and loads it.
    func addRepository(path: String) async {
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        var repository = RepositoryConfig(name: url.lastPathComponent, path: path)
        if let scheme = await ReleaseLoader.guessScheme(url) {
            repository.tagPattern = scheme.pattern
            repository.trainRule = scheme.train
            repository.buildRule = scheme.build
        }
        repositories.append(repository)
        await refresh(repository.id)
    }

    /// Adds a repository from the GitHub or GitLab integration (or returns the one already added):
    /// its local checkout when there is one, else it's read from the integration's mirror in Dash.
    /// Returns its id.
    func addRemote(_ remote: RemoteRepository) async -> String {
        if let existing = repositories.first(where: { $0.source == remote.source }) { return existing.id }
        let checkouts = await ReleasesSettingsView.findCheckouts()
        var repository = RepositoryConfig(name: remote.name, path: await remote.localCheckout(among: checkouts) ?? "")
        repository.source = remote.source
        repositories.append(repository)
        let id = repository.id
        Task {
            // The tag scheme is guessed from the tags, synced first for a remote repository.
            var scheme: TagScheme?
            if repository.isRemote {
                if let source = try? await syncedSource(repository, force: true) { scheme = TagScheme.guess(source.tagList.map(\.name)) }
            } else {
                scheme = await ReleaseLoader.guessScheme(repository.url)
            }
            if let scheme, let index = repositories.firstIndex(where: { $0.id == id }) {
                repositories[index].tagPattern = scheme.pattern
                repositories[index].trainRule = scheme.train
                repositories[index].buildRule = scheme.build
            }
            await refresh(id)
        }
        return id
    }

    // MARK: Mirror

    /// The integration's tool, e.g. github_sync_tags.
    private func syncTool(_ service: String, _ name: String) throws -> ClaudeTool {
        guard let integration = host?.integration(service) else {
            throw ToolError("Install and connect the \(service == "gitlab" ? "GitLab" : "GitHub") integration to read this repository.")
        }
        guard let tool = integration.tools.first(where: { $0.name == "\(service)_\(name)" }) else {
            throw ToolError("Update the \(integration.name) integration: it can't sync release data yet.")
        }
        return tool
    }

    /// Tags from the mirror, synced through the integration first when they're missing, older than
    /// the repository's refresh interval, or `force` is set.
    func syncedSource(_ repository: RepositoryConfig, force: Bool = false) async throws -> SyncedReleaseSource {
        guard let service = repository.service, let slug = repository.slug, let host else { throw ToolError("Releases isn't started.") }
        let scope = repository.source ?? ""
        let synced = host.synced.lastSynced(kind: SyncedReleaseSource.tagKind, scope: scope)
        if force || synced == nil || now().timeIntervalSince(synced ?? .distantPast) >= repository.refreshInterval - 5 {
            _ = try await syncTool(service, "sync_tags").run(["repo": .string(slug)])
        }
        let (tags, onBase) = SyncedReleaseSource.tags(host.synced.records(kind: SyncedReleaseSource.tagKind, scope: scope))
        let defaultBranch = host.synced.record(kind: SyncedReleaseSource.repoKind, scope: scope, key: "info")?.value["default_branch"]?.string ?? "main"
        return SyncedReleaseSource(tagList: tags, onBase: onBase, defaultBranch: defaultBranch) { [weak self] base, head in
            guard let self else { return [] }
            return try await self.syncedRange(service: service, slug: slug, scope: scope, base: base, head: head)
        }
    }

    /// Commits between two commits, from the mirror or fetched once through the integration.
    private func syncedRange(service: String, slug: String, scope: String, base: String, head: String) async throws -> [ReleaseCommit] {
        if let cached = host?.synced.record(kind: SyncedReleaseSource.rangeKind, scope: scope, key: base + "..." + head) {
            return SyncedReleaseSource.commits(cached.value)
        }
        let value = try await syncTool(service, "sync_compare").run(["repo": .string(slug), "base": .string(base), "head": .string(head)])
        return SyncedReleaseSource.commits(value)
    }

    // MARK: Storage

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: "releases.\(key)")
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: "releases.\(key)").flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: Claude tools

    private struct ListInput: Decodable { let repo: String?; let train: String?; let since: String? }
    private struct TagInput: Decodable { let tag: String; let repo: String? }
    private struct DateInput: Decodable { let date: String; let repo: String? }
    private struct TextInput: Decodable { let text: String; let repo: String? }
    private struct EventInput: Decodable { let date: String; let title: String; let kind: String?; let note: String?; let repo: String? }

    var tools: [ClaudeTool] {
        [
            ClaudeTool(
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
            ClaudeTool(
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
            ClaudeTool(
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
            ClaudeTool(
                name: "releases_containing",
                description: "Which release first shipped a change, on each train: give a ticket key (LAF-5917), a commit sha (at least 7 characters) or words from a commit subject.",
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
            ClaudeTool(
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
