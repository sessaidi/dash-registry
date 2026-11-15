import AppKit
import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

struct TagSchemeTests {
    @Test func releaseTagsSplitIntoReleaseTrainAndBuild() throws {
        let scheme = TagScheme.releaseTags
        #expect(scheme.parse("release-2026W23-02-eu.01") == .init(release: "release-2026W23-02-eu", train: "eu", build: 1))
        #expect(scheme.parse("release-2026W23-02-us.12") == .init(release: "release-2026W23-02-us", train: "us", build: 12))
        // No suffix: the shared train. A one-digit build number still counts.
        #expect(scheme.parse("release-2022W20-04.1") == .init(release: "release-2022W20-04", train: "", build: 1))
        #expect(scheme.parse("v1.2.3") == nil)
        #expect(scheme.parse("deploy-test") == nil)
    }

    @Test func semverTagsAreOneTrainEachTagARelease() {
        let scheme = TagScheme.semver
        #expect(scheme.parse("v1.2.3") == .init(release: "v1.2.3", train: "", build: nil))
        #expect(scheme.parse("v2.0.0-rc.1") == .init(release: "v2.0.0-rc.1", train: "", build: nil))
        #expect(scheme.parse("release-2026W23-02.01") == nil)
    }

    @Test func regexPatternsAndTrains() {
        let scheme = TagScheme(pattern: #"^deploy/"#, train: .regex, trainRegex: #"^deploy/(\w+)/"#, build: .none)
        #expect(scheme.parse("deploy/prod/2026-01-01") == .init(release: "deploy/prod/2026-01-01", train: "prod", build: nil))
        #expect(scheme.parse("release-1") == nil)
    }

    @Test func guessesTheScheme() {
        #expect(TagScheme.guess(["v0.1.0", "v0.2.0"]) == .semver)
        #expect(TagScheme.guess(["v0.1.0", "release-2026W01-01.01"]) == .releaseTags)
        #expect(TagScheme.guess(["1.0.0"])?.pattern == #"^\d+\.\d+\.\d+"#)
        #expect(TagScheme.guess(["nightly"]) == nil)
    }

    @Test func ticketKeys() {
        #expect(Tickets.extract("LAF-5917: fix PPT-12 and LAF-5917 again (#81)") == ["LAF-5917", "PPT-12"])
        #expect(Tickets.extract("ABC1-3 and A-1 and lower-12") == ["ABC1-3"])
        #expect(Tickets.isKey("laf-5917") && !Tickets.isKey("hello"))
    }

    @Test func commitGroupsPutDependenciesLast() {
        func commit(_ subject: String) -> ReleaseCommit { ReleaseCommit(sha: UUID().uuidString, author: "a", date: .now, subject: subject, alreadyShipped: false) }
        let groups = CommitGroups.group([commit("LAF-1: a"), commit("LAF-2: b"), commit("PPT-1: c"), commit("chore(deps): Bump x"), commit("tidy")])
        #expect(groups.map(\.title) == ["LAF changes", "PPT changes", "Other", "Dependencies & translations"])
    }

    @Test func dates() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day = try #require(ReleaseDates.parse("2026-06-05", now: now, calendar: calendar))
        #expect(calendar.component(.hour, from: day) == 23 && calendar.component(.day, from: day) == 5)
        #expect(ReleaseDates.parse(ReleaseDates.day(now), now: now, calendar: calendar) == now)
        #expect(ReleaseDates.parse("not a date") == nil)
    }
}

struct EraTests {
    private func tag(_ name: String, _ day: Double) -> TagInfo {
        TagInfo(name: name, date: TempRepo.day(day), commit: name, subject: name)
    }

    @Test func buildsGroupIntoReleasesAndTrains() {
        let tags = [tag("release-2026W02-01.01", 0), tag("release-2026W03-01.01", 7), tag("release-2026W04-01-eu.01", 14),
                    tag("release-2026W04-01-eu.02", 16), tag("release-2026W04-02-us.01", 15), tag("v1.0.0", 3)]
        let timeline = ReleaseGrouping.timeline(tags, repository: RepositoryConfig(name: "x", path: "/tmp"), onBase: Set(tags.map(\.name)), now: TempRepo.day(60))
        #expect(timeline.trains == ["", "eu", "us"])
        #expect(timeline.releases.map(\.name) == ["release-2026W02-01", "release-2026W03-01", "release-2026W04-01-eu", "release-2026W04-02-us"])
        let eu = try! #require(timeline.release(named: "release-2026W04-01-eu.02"))
        #expect(eu.builds.map(\.tag) == ["release-2026W04-01-eu.01", "release-2026W04-01-eu.02"])
        #expect(eu.start == TempRepo.day(14) && eu.lastBuild.date == TempRepo.day(16))
        #expect(timeline.trainTitle("") == "Shared" && timeline.trainTitle("eu") == "EU")
    }

    @Test func eraEndsAtTheNextReleaseAfterIdleDaysOrToday() {
        let tags = [tag("release-2026W02-01-eu.01", 0), tag("release-2026W03-01-eu.01", 7), tag("release-2026W10-01-eu.01", 60),
                    tag("release-2026W02-01-us.01", 1)]
        let now = TempRepo.day(100)
        let timeline = ReleaseGrouping.timeline(tags, repository: RepositoryConfig(name: "x", path: "/tmp", idleDays: 30), onBase: [], now: now)
        let eu = timeline.releases(on: "eu")
        // Next release within 30 days: ends when it starts.
        #expect(eu[0].end == TempRepo.day(7) && eu[0].endReason == .next && eu[0].next == eu[1].name)
        // Next release 53 days later: the era stops 30 days after its last build.
        #expect(eu[1].end == TempRepo.day(37) && eu[1].endReason == .idle && eu[1].next == nil)
        // The last one runs to today, even 40 days on.
        #expect(eu[2].end == now && eu[2].endReason == .today && eu[2].isCurrent)
        // A named train that went quiet still has its last release live (no handover between named trains).
        #expect(timeline.releases(on: "us")[0].isCurrent)
        #expect(eu.map(\.index) == [0, 1, 2] && eu.allSatisfy { $0.trainCount == 3 })
    }

    @Test func sharedTrainHandsOverToNamedTrains() {
        let tags = [tag("release-2026W02-01.01", 0), tag("release-2026W03-01.01", 7), tag("release-2026W04-01-eu.01", 14)]
        let timeline = ReleaseGrouping.timeline(tags, repository: RepositoryConfig(name: "x", path: "/tmp"), onBase: [], now: TempRepo.day(90))
        let shared = timeline.releases(on: "")
        #expect(shared[1].end == TempRepo.day(14) && shared[1].endReason == .handover)
        // The first eu release is compared with the shared release live when it started.
        #expect(timeline.release(named: "release-2026W04-01-eu")?.base == "release-2026W03-01.01")
        // Before the idle period is over the shared train is still current.
        let early = ReleaseGrouping.timeline(tags, repository: RepositoryConfig(name: "x", path: "/tmp"), onBase: [], now: TempRepo.day(20))
        #expect(early.releases(on: "")[1].isCurrent)
    }
}

/// Everything against a real repository built here (git init, commits, tags, a hotfix branch).
@MainActor
struct GitTimelineTests {
    @Test func readsTagsHotfixesAndCommits() async throws {
        let (repo, shas) = try TempRepo.scenario()
        let config = RepositoryConfig(name: "api", path: repo.url.path)
        let timeline = try await ReleaseLoader().load(config, now: TempRepo.day(120))
        #expect(timeline.baseBranch == "main")
        #expect(timeline.trains == ["", "eu", "us"])
        #expect(timeline.releases.count == 6)
        #expect(!timeline.releases.flatMap(\.builds).contains { $0.tag == "deploy-test" })

        // Hotfix: eu.02's commit is only on the hotfix branch.
        let hotfix = try #require(timeline.release(named: "release-2026W04-01-eu"))
        #expect(hotfix.isHotfix)
        #expect(hotfix.builds.map(\.onBase) == [true, false])
        #expect(timeline.release(named: "release-2026W05-01-eu")?.isHotfix == false)

        // Commits per build: c3 came with .01 (compared with the shared release), h1 with .02.
        #expect(hotfix.base == "release-2026W03-01.01")
        #expect(hotfix.commits.map(\.sha) == [shas["h1"], shas["c3"]])
        #expect(hotfix.commits.first { $0.sha == shas["h1"] }?.build == "release-2026W04-01-eu.02")
        #expect(hotfix.tickets == ["LAF-20", "PPT-5"])

        // Cherry-pick: the next eu release has the same fix again, flagged as already shipped.
        let next = try #require(timeline.release(named: "release-2026W05-01-eu.01"))
        #expect(next.base == "release-2026W04-01-eu.02")
        #expect(next.commits.count == 2)
        #expect(next.commits.first { $0.sha == shas["m1"] }?.alreadyShipped == true)
        #expect(next.newCommits.map(\.sha) == [shas["m2"]])
        #expect(next.tickets == ["LAF-21"])
        #expect(next.authors == ["Tester"])

        // The us train never had the hotfix: the fix is new there.
        let us = try #require(timeline.release(named: "release-2026W06-02-us"))
        #expect(us.newCommits.map(\.subject).sorted() == ["LAF-20: urgent fix", "LAF-21: next feature"])

        // First release ever: nothing to compare with.
        #expect(timeline.release(named: "release-2026W02-01")?.base == nil)

        // Eras: the shared train handed over to eu; the latest of each named train runs to today.
        #expect(timeline.release(named: "release-2026W03-01")?.endReason == .handover)
        #expect(next.isCurrent && us.isCurrent)
        #expect(hotfix.end == TempRepo.day(21) && hotfix.endReason == .next)
    }

    @Test func liveAtADate() async throws {
        let (repo, _) = try TempRepo.scenario()
        let timeline = try await ReleaseLoader().load(RepositoryConfig(name: "api", path: repo.url.path), now: TempRepo.day(120))
        func live(_ day: Double) -> [String: String] {
            Dictionary(uniqueKeysWithValues: timeline.liveAt(TempRepo.day(day)).map { ($0.train, $0.build.tag) })
        }
        #expect(live(3) == ["": "release-2026W02-01.01"])
        // The shared train handed over on day 14: only eu is live before us starts.
        #expect(live(14.5) == ["eu": "release-2026W04-01-eu.01"])
        #expect(live(16.5) == ["eu": "release-2026W04-01-eu.02", "us": "release-2026W04-02-us.01"])
        #expect(live(50) == ["eu": "release-2026W05-01-eu.01", "us": "release-2026W06-02-us.01"])
        #expect(live(-1).isEmpty)
    }

    @Test func releasesContainingATicketOrCommit() async throws {
        let (repo, shas) = try TempRepo.scenario()
        let timeline = try await ReleaseLoader().load(RepositoryConfig(name: "api", path: repo.url.path), now: TempRepo.day(120))
        func first(_ text: String) async throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try await ReleasesFeature.containing(text, in: timeline).map { ($0.train, $0.release.name) })
        }
        // The hotfix shipped LAF-20 on eu; us got it with its next release.
        #expect(try await first("LAF-20") == ["eu": "release-2026W04-01-eu", "us": "release-2026W06-02-us"])
        #expect(try await first("laf-21") == ["eu": "release-2026W05-01-eu", "us": "release-2026W06-02-us"])
        #expect(try await first(String(shas["m2"]!.prefix(10))) == ["eu": "release-2026W05-01-eu", "us": "release-2026W06-02-us"])
        // c1 is older than any compared range: found through the release heads' history.
        #expect(try await first(String(shas["c1"]!.prefix(8))) == ["": "release-2026W02-01", "eu": "release-2026W04-01-eu", "us": "release-2026W04-02-us"])
        #expect(try await first("nothing like this").isEmpty)
    }

    @Test func semverRepositoryIsOneTrain() async throws {
        let repo = try TempRepo()
        try repo.commit("feat: one", file: "a", content: "1", day: 0)
        try repo.tag("v1.0.0", day: 0)
        try repo.commit("ABC-1: two", file: "a", content: "2", day: 10)
        try repo.tag("v1.1.0", day: 10)
        #expect(await ReleaseLoader.guessScheme(repo.url) == .semver)
        var config = RepositoryConfig(name: "lib", path: repo.url.path)
        config.tagPattern = "v*"; config.trainRule = .none; config.buildRule = .none
        let timeline = try await ReleaseLoader().load(config, now: TempRepo.day(20))
        #expect(timeline.trains == [""] && timeline.trainTitle("") == "Releases")
        #expect(timeline.releases.map(\.name) == ["v1.0.0", "v1.1.0"])
        #expect(timeline.releases[1].tickets == ["ABC-1"])
    }

    @Test func commitRangesSurviveARelaunch() async throws {
        let (repo, _) = try TempRepo.scenario()
        let cacheFile = repo.url.appending(path: ".git/releases-cache.json")
        let config = RepositoryConfig(name: "api", path: repo.url.path)
        let first = try await ReleaseLoader(cacheFile: cacheFile).load(config, now: TempRepo.day(120))
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
        let loader = ReleaseLoader(cacheFile: cacheFile)
        let second = try await loader.load(config, now: TempRepo.day(120))
        #expect(second.releases.map(\.commits) == first.releases.map(\.commits))
        // Five ranges: eu and us both start from the shared release with c3 (one range).
        #expect(await loader.cachedRanges == 5)
    }

    @Test func missingCheckoutFails() async {
        await #expect(throws: ToolError.self) {
            try await ReleaseLoader().load(RepositoryConfig(name: "gone", path: "/nonexistent/\(UUID())"))
        }
    }
}

@MainActor
struct FeatureTests {
    private func makeFeature() -> ReleasesFeature {
        ReleasesFeature(defaults: UserDefaults(suiteName: "releases-tests-\(UUID().uuidString)")!, cacheFile: nil)
    }

    @Test func startsWithNoRepositories() async throws {
        let feature = makeFeature()
        #expect(feature.repositories.isEmpty)
        let host = try TestHost([feature])
        await #expect(throws: ToolError.self) { try await host.runTool("releases_list") }
    }

    @Test func toolsAnswerFromTheRepository() async throws {
        let (repo, shas) = try TempRepo.scenario()
        let feature = makeFeature()
        feature.now = { TempRepo.day(120) }
        await feature.addRepository(path: repo.url.path)
        #expect(feature.repositories.first?.tagPattern == "release-*")
        #expect(feature.timelines.count == 1)
        let host = try TestHost([feature])

        let list = try #require(try await host.runTool("releases_list", ["train": "eu"])?.array?.first)
        #expect(list["releases"]?.array?.map { $0["release"]?.string } == ["release-2026W05-01-eu", "release-2026W04-01-eu"])
        #expect(list["releases"]?.array?.last?["hotfix"] == .bool(true))
        let since = try await host.runTool("releases_list", ["since": "2026-02-05"])?.array?.first?["releases"]?.array
        #expect(since?.count == 2)

        let detail = try #require(try await host.runTool("release_detail", ["tag": "release-2026W05-01-eu.01"]))
        #expect(detail["previous"] == "release-2026W04-01-eu")
        #expect(detail["already_shipped"] == .number(1))
        #expect(detail["tickets"] == ["LAF-21"])

        let live = try await host.runTool("release_live_at", ["date": "2026-01-21"])?.array?.first?["live"]?.array
        #expect(Set(live?.compactMap { $0["tag"]?.string } ?? []) == ["release-2026W04-01-eu.02", "release-2026W04-02-us.01"])

        let containing = try await host.runTool("releases_containing", ["text": .string(shas["h1"]!)])?.array?.first?["first_shipped"]?.array
        #expect(containing?.first?["release"] == "release-2026W04-01-eu")

        await #expect(throws: ToolError.self) { try await host.runTool("release_detail", ["tag": "release-1999W01-01.01"]) }
        await #expect(throws: ToolError.self) { try await host.runTool("releases_list", ["repo": "other"]) }
    }

    @Test func eventsAreStoredAndNeedApproval() async throws {
        let suite = "releases-tests-\(UUID().uuidString)"
        let feature = ReleasesFeature(defaults: UserDefaults(suiteName: suite)!, cacheFile: nil)
        feature.repositories = [RepositoryConfig(name: "api", path: "/tmp")]
        let host = try TestHost([feature])
        let tool = try #require(feature.tools.first { $0.name == "release_events_add" })
        #expect(tool.requiresApproval)
        #expect(feature.tools.filter { $0.name != "release_events_add" }.allSatisfy { !$0.requiresApproval })
        _ = try await host.runTool("release_events_add", ["date": "2026-03-05", "title": "Checkout incident", "kind": "incident", "repo": "api"])
        #expect(feature.timelineEvents.first?.kind == .incident && feature.timelineEvents.first?.repository == feature.repositories[0].id)
        await #expect(throws: ToolError.self) { try await host.runTool("release_events_add", ["date": "soon", "title": "x"]) }
        // Stored in preferences: a new instance reads them back.
        let again = ReleasesFeature(defaults: UserDefaults(suiteName: suite)!, cacheFile: nil)
        #expect(again.timelineEvents.map(\.title) == ["Checkout incident"] && again.repositories.map(\.name) == ["api"])
        #expect(again.events(for: "someone-else").isEmpty && again.events(for: nil).count == 1)
    }

    @Test func remoteRepositoryReadsTheIntegrationMirror() async throws {
        let github = FakeGitHub()
        let feature = makeFeature()
        feature.now = { TempRepo.day(40) }
        let host = try TestHost([github, feature])
        github.hostStore = host.synced
        feature.start(host: host)
        feature.stop()
        let remote = try #require(RemoteRepository.available(host: host).first)
        #expect(remote.source == "github:acme/api" && remote.host == "github.com")

        let id = await feature.addRemote(remote)
        #expect(await feature.addRemote(remote) == id)
        let repository = try #require(feature.repositories.first)
        #expect(repository.isRemote && repository.slug == "acme/api" && repository.service == "github")
        await feature.refresh(id)
        let timeline = try #require(feature.timelines[id])
        #expect(timeline.releases.map(\.name) == ["release-2026W02-01", "release-2026W03-01", "release-2026W04-01"])
        #expect(timeline.baseBranch == "main")
        // The fix W03 shipped comes back in W04's range: counted as already shipped (same subject).
        let latest = try #require(timeline.releases.last)
        #expect(latest.newCommits.map(\.subject) == ["PPT-5: third"] && latest.commits.count == 2)
        #expect(github.calls.filter { $0 == "github_sync_tags" }.count >= 1)
        // Ranges are fetched once, then read from the mirror.
        let compares = github.calls.filter { $0 == "github_sync_compare" }.count
        await feature.refresh(id)
        #expect(github.calls.filter { $0 == "github_sync_compare" }.count == compares)
        // A repository can't be read without its integration.
        var orphan = RepositoryConfig(name: "web", path: "")
        orphan.source = "gitlab:acme/web"
        await #expect(throws: ToolError.self) { try await feature.syncedSource(orphan) }
    }

    @Test func searchesParseDates() {
        let now = TempRepo.day(300) // 2026-11-01
        let utc = { () -> Calendar in var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; return calendar }()
        func day(_ date: Date?) -> String? { date.map { $0.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()) } }
        #expect(day(ReleaseDates.search("2026-10-12", now: now, calendar: utc)) == "2026-10-12")
        #expect(day(ReleaseDates.search("12 Oct", now: now, calendar: utc)) == "2026-10-12")
        #expect(day(ReleaseDates.search("Oct 12", now: now, calendar: utc)) == "2026-10-12")
        // No year, in the future: last year's.
        #expect(day(ReleaseDates.search("12 Dec", now: now, calendar: utc)) == "2025-12-12")
        #expect(day(ReleaseDates.search("12 October 2025", now: now, calendar: utc)) == "2025-10-12")
        #expect(day(ReleaseDates.search("W41", now: now, calendar: utc)) == "2026-10-05")
        #expect(day(ReleaseDates.search("2026W02", now: now, calendar: utc)) == "2026-01-05")
        #expect(ReleaseDates.search("LAF-5917", now: now, calendar: utc) == nil)
        #expect(ReleaseDates.search("fix", now: now, calendar: utc) == nil)
    }

    @Test func widgetContract() {
        #expect(ReleaseTimelineWidget.kind == "releases.timeline")
        let type = WidgetType(ReleaseTimelineWidget.self)
        #expect(type.preview != nil && type.hasSettings)
        #expect(ReleaseSamples.timeline.trains == ["", "eu", "us"])
    }

    @Test func layoutHitTestsEras() {
        let timeline = ReleaseSamples.timeline
        let model = TimelineModel(timelines: [timeline], events: [], train: "eu", showEvents: false)
        let domain = ReleaseSamples.now.addingTimeInterval(-80 * 86_400)...ReleaseSamples.now
        let layout = TimelineLayout(size: CGSize(width: 800, height: 200), domain: domain, compact: false, lanes: model.lanes)
        let latest = timeline.releases(on: "eu").last!
        let band = layout.bands[0].rect
        let hit = layout.release(at: CGPoint(x: layout.x(latest.start) + 2, y: band.midY))
        #expect(hit?.id == latest.id)
        #expect(layout.release(at: CGPoint(x: 10, y: band.midY)) == nil)
        #expect(!layout.ticks().isEmpty)
        // Narrow widgets get the compact layout: a thinner label column.
        #expect(TimelineLayout(size: CGSize(width: 300, height: 100), domain: domain, compact: true, lanes: model.lanes).labelWidth < layout.labelWidth)
    }
}

/// Opt-in: TEST_RUNNER_DASH_RELEASES_LIVE=<checkout> reads a real repository (read-only git) and prints what it found.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_RELEASES_LIVE"] != nil))
func liveRepository() async throws {
    let path = ProcessInfo.processInfo.environment["DASH_RELEASES_LIVE"]!
    let cacheFile = FileManager.default.temporaryDirectory.appending(path: "releases-live-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheFile) }
    let started = Date()
    let loader = ReleaseLoader(cacheFile: cacheFile)
    let config = RepositoryConfig(name: URL(filePath: path).lastPathComponent, path: path)
    let timeline = try await loader.load(config)
    let seconds = Date().timeIntervalSince(started)
    // A relaunch: a new loader reading the ranges back from the cache file.
    let again = Date()
    let reloaded = try await ReleaseLoader(cacheFile: cacheFile).load(config)
    let cached = Date().timeIntervalSince(again)
    #expect(reloaded.releases.map(\.commits) == timeline.releases.map(\.commits))
    let builds = timeline.releases.flatMap(\.builds).sorted { $0.date < $1.date }
    var lines = ["RELEASESLIVE repo=\(path) base=\(timeline.baseBranch) load=\(String(format: "%.1f", seconds))s reload=\(String(format: "%.2f", cached))s ranges=\(await loader.cachedRanges)",
                 "RELEASESLIVE tags=\(builds.count) releases=\(timeline.releases.count) trains=\(timeline.trains.map(timeline.trainTitle))",
                 "RELEASESLIVE first=\(builds.first?.tag ?? "-") (\(builds.first.map { ReleaseDates.day($0.date) } ?? "-")) last=\(builds.last?.tag ?? "-") (\(builds.last.map { ReleaseDates.day($0.date) } ?? "-"))"]
    for train in timeline.trains {
        let releases = timeline.releases(on: train)
        lines.append("RELEASESLIVE train \(timeline.trainTitle(train)): \(releases.count) releases, \(releases.filter(\.isHotfix).count) hotfix, \(releases.reduce(0) { $0 + $1.builds.count }) builds, first \(releases.first?.name ?? "-"), last \(releases.last?.name ?? "-") ends \(releases.last?.endReason.rawValue ?? "-")")
    }
    lines.append("RELEASESLIVE live now: " + timeline.liveAt(.now).map { "\(timeline.trainTitle($0.train))=\($0.build.tag)" }.joined(separator: " "))
    if let latest = timeline.releases.last {
        lines.append("RELEASESLIVE latest \(latest.name): \(latest.newCommits.count) new, \(latest.commits.count - latest.newCommits.count) already shipped, tickets \(latest.tickets.prefix(8))")
    }
    let shipped = timeline.releases.reduce(0) { $0 + $1.commits.count - $1.newCommits.count }
    lines.append("RELEASESLIVE commits total=\(timeline.releases.reduce(0) { $0 + $1.commits.count }) already-shipped=\(shipped)")
    if let ticket = timeline.releases.last?.tickets.first {
        let hits = try await ReleasesFeature.containing(ticket, in: timeline)
        lines.append("RELEASESLIVE containing \(ticket): " + hits.map { "\(timeline.trainTitle($0.train))=\($0.release.name)" }.joined(separator: " "))
    }
    let text = lines.joined(separator: "\n")
    print(text)
    try? text.write(to: FileManager.default.temporaryDirectory.appending(path: "releases-live.txt"), atomically: true, encoding: .utf8)
    #expect(!timeline.releases.isEmpty)
}

/// Opt-in: TEST_RUNNER_DASH_RELEASES_RENDER=<folder> draws the widget (narrow and wide) to PNGs there,
/// from the sample data, or from DASH_RELEASES_LIVE's repository when set.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_RELEASES_RENDER"] != nil))
func renderWidget() async throws {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["DASH_RELEASES_RENDER"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let feature = ReleasesFeature(defaults: UserDefaults(suiteName: "releases-render-\(UUID().uuidString)")!, cacheFile: nil)
    let host = try TestHost([feature])
    if let live = ProcessInfo.processInfo.environment["DASH_RELEASES_LIVE"] {
        await feature.addRepository(path: live)
    } else {
        let (repo, _) = try TempRepo.scenario()
        feature.now = { TempRepo.day(40) }
        await feature.addRepository(path: repo.url.path)
    }
    feature.timelineEvents = [ReleaseEvent(date: feature.now().addingTimeInterval(-20 * 86_400), kind: .incident, title: "Incident"),
                              ReleaseEvent(date: feature.now().addingTimeInterval(-50 * 86_400), kind: .launch, title: "Launch")]
    for (name, size, period) in [("wide", CGSize(width: 900, height: 330), 90), ("narrow", CGSize(width: 300, height: 260), 90), ("all", CGSize(width: 900, height: 330), 0)] {
        let config = ReleaseTimelineWidget.Config(period: period == 0 ? nil : period)
        let view = ReleaseTimelineView(feature: feature, host: host, config: .constant(config))
            .padding(12).frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "releases-\(name).png"))
    }
    // ImageRenderer leaves ScrollViews blank: draw the chart itself too.
    let timeline = try #require(feature.timelines.values.first)
    let now = feature.now()
    for (name, width, days, compact) in [("chart-wide", 900.0, 90.0, false), ("chart-narrow", 300.0, 90.0, true), ("chart-year", 900.0, 365.0, false)] {
        let model = TimelineModel(timelines: [timeline], events: feature.timelineEvents, train: nil, showEvents: true)
        let domain = now.addingTimeInterval(-days * 86_400)...now.addingTimeInterval(days * 0.04 * 86_400)
        let height = TimelineLayout(size: CGSize(width: width, height: 0), domain: domain, compact: compact, lanes: model.lanes).height
        let chart = TimelineChart(model: model, domain: domain, now: now, compact: compact, selected: timeline.releases.last?.id, hovered: nil, query: "")
            .frame(width: width, height: height).padding(8).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: chart)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: folder.appending(path: "releases-\(name).png"))
    }
    let detail = ReleaseDetailSheet(feature: feature, repository: feature.repositories[0].id, releaseID: feature.timelines.values.first!.releases.last!.id)
        .frame(width: 760, height: 640).background(Color.white).environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: detail)
    renderer.scale = 1.5
    let tiff = try #require(renderer.nsImage?.tiffRepresentation)
    try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: folder.appending(path: "releases-detail.png"))
}

/// A GitHub integration whose sync tools write a canned repository into the host's mirror.
@MainActor
final class FakeGitHub: Integration {
    let id = "github"
    let name = "GitHub"
    let systemImage = "chevron.left.forwardslash.chevron.right"
    var isConnected: Bool { true }
    var connection: IntegrationConnection? { nil }
    var exports: JSONValue { ["repos": ["acme/api"], "webURL": "https://github.com"] }
    private(set) var calls: [String] = []

    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start(host: any ExtensionContext) {}

    static func iso(_ day: Double) -> JSONValue { .string(TempRepo.day(day).formatted(.iso8601)) }

    var tools: [ClaudeTool] {
        [
            ClaudeTool(name: "github_sync_tags", description: "") { [weak self] _ in
                guard let self, let store = self.hostStore else { return nil }
                calls.append("github_sync_tags")
                let scope = "github:acme/api"
                store.replace(kind: "git.tag", scope: scope, with: [("release-2026W02-01.01", "c1", 0.0), ("release-2026W03-01.01", "c2", 7), ("release-2026W04-01.01", "c3", 14)].map { tag in
                    SyncedRecord(kind: "git.tag", scope: scope, key: tag.0,
                                 value: ["commit": .string(tag.1), "date": Self.iso(tag.2), "subject": "", "on_base": true], source: "github")
                })
                store.replace(kind: "git.repo", scope: scope, with: [SyncedRecord(kind: "git.repo", scope: scope, key: "info", value: ["default_branch": "main"], source: "github")])
                return ["tags": 3]
            },
            ClaudeTool(name: "github_sync_compare", description: "") { [weak self] input in
                guard let self, let store = self.hostStore else { return nil }
                calls.append("github_sync_compare")
                let base = input["base"]?.string ?? "", head = input["head"]?.string ?? ""
                let commits: JSONValue = switch (base, head) {
                case ("c1", "c2"): [["sha": "x2", "author": "Ann", "date": Self.iso(6), "subject": "LAF-10: second"]]
                case ("c2", "c3"): [["sha": "x3", "author": "Ann", "date": Self.iso(12), "subject": "LAF-10: second"],
                                    ["sha": "x4", "author": "Bob", "date": Self.iso(13), "subject": "PPT-5: third"]]
                default: []
                }
                store.upsert([SyncedRecord(kind: "git.range", scope: "github:acme/api", key: base + "..." + head, value: commits, source: "github")])
                return commits
            },
        ]
    }

    /// The mirror of the host the feature runs in, set by the test.
    var hostStore: (any SyncedStore)?
}

@MainActor
struct ReleaseTimelineActionsTests {
    @Test func dashiiCanDriveTheTimeline() {
        #expect(ReleaseTimelineWidget.actions.map(\.name) == ["search", "select_release", "set_train", "set_period", "zoom", "clear"])
        #expect(WidgetType(ReleaseTimelineWidget.self).actions.count == 6)
    }

    @Test func trainsAndReleasesAreFoundByWhatTheUserSays() throws {
        #expect(ReleaseTimelineActions.train("All") == nil)
        #expect(ReleaseTimelineActions.train(nil) == nil)
        #expect(ReleaseTimelineActions.train("shared") == "")
        #expect(ReleaseTimelineActions.train(" EU ") == "eu")

        let releases = ReleaseSamples.timeline.releases
        let release = try #require(releases.last)
        #expect(ReleaseTimelineActions.find(release.name.uppercased(), in: releases)?.id == release.id)
        #expect(ReleaseTimelineActions.find(release.shortName, in: releases)?.id == release.id)
        #expect(ReleaseTimelineActions.find(try #require(release.builds.first?.tag), in: releases)?.id == release.id)
        #expect(ReleaseTimelineActions.find("no-such-release", in: releases) == nil)
        #expect(ReleaseTimelineActions.day(Date(timeIntervalSince1970: 0)) == "1970-01-01")
    }
}
