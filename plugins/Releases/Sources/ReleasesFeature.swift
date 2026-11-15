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
        category: .sourceControl, tags: ["git", "releases", "timeline"], minimumDashKit: "2.0.0")

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

    /// Shows `timeline` without reading git: the widget gallery's sample data.
    func showSample(_ timeline: RepositoryTimeline, events: [ReleaseEvent], now: Date) {
        repositories = [timeline.repository]
        timelines[timeline.repository.id] = timeline
        timelineEvents = events
        self.now = { now }
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
    private func syncTool(_ service: String, _ name: String) throws -> DashiiTool {
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
}
