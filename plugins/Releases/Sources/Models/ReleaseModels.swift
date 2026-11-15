import Foundation

// MARK: - Settings

/// One repository the user added in Settings, and how to read its release tags.
struct RepositoryConfig: Codable, Hashable, Identifiable, Sendable {
    /// How a tag names its train ("release-2026W23-02-eu.01" is on "eu").
    enum TrainRule: String, Codable, CaseIterable, Sendable {
        /// A short letters-only suffix before the build number (-eu, -us); no suffix is the shared train.
        case suffix
        /// One train for every tag.
        case none
        /// The first capture group of `trainRegex`; no match is the shared train.
        case regex

        var title: String {
            switch self {
            case .suffix: "Suffix (-eu, -us)"
            case .none: "One train"
            case .regex: "Regular expression"
            }
        }
    }

    /// How a tag names its build ("….02" is the second build of a release).
    enum BuildRule: String, Codable, CaseIterable, Sendable {
        /// A trailing ".NN": tags that differ only by it are builds of one release.
        case suffix
        /// Every tag is its own release (semver).
        case none

        var title: String {
            switch self {
            case .suffix: "Suffix (.01, .02)"
            case .none: "Each tag is a release"
            }
        }
    }

    var id: String = UUID().uuidString
    var name: String
    /// Local checkout.
    var path: String
    /// A glob ("release-*", "v*") or, starting with ^, a regular expression.
    var tagPattern: String = "release-*"
    var trainRule: TrainRule = .suffix
    var trainRegex: String = ""
    var buildRule: BuildRule = .suffix
    /// Branch a build's commit must be on not to count as a hotfix; empty is origin's HEAD.
    var baseBranch: String = ""
    /// A train that goes quiet this long ends its last release's era.
    var idleDays: Int = 30
    /// Where it came from when added from an integration: "github:owner/name" or
    /// "gitlab:group/project". Empty for a checkout added by hand.
    var source: String?
    /// How often to check for new tags, in minutes (nil is every 10).
    var refreshMinutes: Int?

    /// Read from the integration's mirror in Dash (no local checkout): `path` is empty.
    var isRemote: Bool { path.isEmpty && !(source ?? "").isEmpty }
    /// "github" or "gitlab" for a remote repository.
    var service: String? { source?.split(separator: ":").first.map(String.init) }
    /// "owner/name" or "group/project" for a remote repository.
    var slug: String? { source?.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) }
    var refreshInterval: TimeInterval { TimeInterval(max(1, refreshMinutes ?? 10) * 60) }

    var url: URL { URL(filePath: (path as NSString).expandingTildeInPath) }

    var scheme: TagScheme { TagScheme(pattern: tagPattern, train: trainRule, trainRegex: trainRegex, build: buildRule) }
}

// MARK: - Tags

/// Reads release tags: which ones count, their release, train and build number.
struct TagScheme: Sendable, Hashable {
    var pattern: String
    var train: RepositoryConfig.TrainRule
    var trainRegex: String = ""
    var build: RepositoryConfig.BuildRule

    static let releaseTags = TagScheme(pattern: "release-*", train: .suffix, build: .suffix)
    static let semver = TagScheme(pattern: "v*", train: .none, build: .none)

    struct Parsed: Hashable, Sendable {
        /// The tag without its build number: what all builds of one release share.
        let release: String
        /// "" is the shared train.
        let train: String
        let build: Int?
    }

    func matches(_ tag: String) -> Bool {
        if pattern.hasPrefix("^") { return (try? Regex(pattern)).map { tag.contains($0) } ?? false }
        return fnmatch(pattern.isEmpty ? "*" : pattern, tag, 0) == 0
    }

    /// nil when the tag doesn't match the pattern.
    func parse(_ tag: String) -> Parsed? {
        guard matches(tag) else { return nil }
        var release = tag
        var number: Int?
        if build == .suffix, let match = tag.wholeMatch(of: /(.+)\.(\d+)/) {
            release = String(match.1)
            number = Int(match.2)
        }
        let trainName: String
        switch train {
        case .none:
            trainName = ""
        case .suffix:
            trainName = release.wholeMatch(of: /.+-([A-Za-z]{2,3})/).map { String($0.1).lowercased() } ?? ""
        case .regex:
            let regex = try? Regex(trainRegex)
            let match = regex.flatMap { try? $0.firstMatch(in: tag) }
            trainName = match.flatMap { $0.count > 1 ? $0[1].substring.map(String.init) : nil }?.lowercased() ?? ""
        }
        return Parsed(release: release, train: trainName, build: number)
    }

    /// The scheme a repository's tags most likely follow: release-* builds, else semver, else nil.
    static func guess(_ tags: [String]) -> TagScheme? {
        if tags.contains(where: { $0.hasPrefix("release-") }) { return .releaseTags }
        if tags.contains(where: { $0.wholeMatch(of: /v\d+\.\d+(\.\d+)?.*/) != nil }) { return .semver }
        if tags.contains(where: { $0.wholeMatch(of: /\d+\.\d+\.\d+.*/) != nil }) {
            return TagScheme(pattern: #"^\d+\.\d+\.\d+"#, train: .none, build: .none)
        }
        return nil
    }
}

/// One tag as git reports it.
struct TagInfo: Hashable, Sendable {
    let name: String
    let date: Date
    /// The tagged commit (peeled for annotated tags).
    let commit: String
    let subject: String
}

/// One release tag: a build of a release.
struct Build: Hashable, Sendable, Identifiable {
    var id: String { tag }
    let tag: String
    let number: Int?
    let date: Date
    let commit: String
    let subject: String
    /// The commit is on the base branch; false is a hotfix branch.
    let onBase: Bool

    var shortCommit: String { String(commit.prefix(9)) }
}

/// A commit a release brought, with what the timeline needs.
struct ReleaseCommit: Hashable, Sendable, Identifiable, Codable {
    var id: String { sha }
    let sha: String
    let author: String
    let date: Date
    let subject: String
    /// The release before already shipped the same change (a cherry-pick with the same patch;
    /// for a repository read from the mirror, the same subject).
    var alreadyShipped: Bool
    /// The build that brought it.
    var build: String = ""

    var shortSHA: String { String(sha.prefix(9)) }
    var tickets: [String] { Tickets.extract(subject) }
}

enum Tickets {
    /// LAF-5917, PPT-12, ABC1-3.
    static func extract(_ text: String) -> [String] {
        var seen: [String] = []
        for match in text.matches(of: /\b[A-Z][A-Z0-9]{1,9}-\d+\b/) where !seen.contains(String(match.0)) {
            seen.append(String(match.0))
        }
        return seen
    }

    static func isKey(_ text: String) -> Bool { text.wholeMatch(of: /[A-Za-z][A-Za-z0-9]{1,9}-\d+/) != nil }
}

// MARK: - Releases

/// Builds of one release (.01, .02…), the time it was the train's release, and what it brought.
struct Release: Hashable, Sendable, Identifiable {
    enum EndReason: String, Sendable, Codable {
        /// The next release on the train replaced it.
        case next
        /// The train went quiet: the era stops `idleDays` after its last build.
        case idle
        /// Another train took over (the train was split).
        case handover
        /// Still live.
        case today
    }

    var id: String { repository + "|" + name }
    let repository: String
    /// Tag without the build number, e.g. "release-2026W23-02-eu".
    let name: String
    let train: String
    /// Oldest first.
    let builds: [Build]
    var end: Date = .distantFuture
    var endReason: EndReason = .today
    /// Index in its train, oldest first.
    var index = 0
    var trainCount = 1
    var previous: String?
    var next: String?
    /// What the commits were compared with: the release live on the train (or the shared one) just before.
    var base: String?
    var commits: [ReleaseCommit] = []
    var commitsTruncated = false

    var start: Date { builds.first?.date ?? .distantPast }
    var lastBuild: Build { builds[builds.count - 1] }
    /// A build's commit isn't on the base branch.
    var isHotfix: Bool { builds.contains { !$0.onBase } }
    var isCurrent: Bool { endReason == .today }
    var newCommits: [ReleaseCommit] { commits.filter { !$0.alreadyShipped } }
    var tickets: [String] { Array(Set(newCommits.flatMap(\.tickets))).sorted() }
    var authors: [String] { Array(Set(newCommits.map(\.author))).sorted() }
    var days: Double { end.timeIntervalSince(start) / 86_400 }

    /// "W23-02-eu" from "release-2026W23-02-eu": the part that tells releases apart.
    var shortName: String { Release.short(name) }

    static func short(_ tag: String) -> String {
        if let match = tag.wholeMatch(of: /release-\d{4}(.+)/) { return String(match.1) }
        return tag
    }

    /// Search text: names, tags, commits, tickets and authors (lowercased).
    var haystack: String {
        ([name, train] + builds.flatMap { [$0.tag, $0.commit, $0.subject] } + commits.flatMap { [$0.sha, $0.subject, $0.author] })
            .joined(separator: " ").lowercased()
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || haystack.contains(query)
    }
}

/// Every release of one repository, by train.
struct RepositoryTimeline: Sendable {
    let repository: RepositoryConfig
    /// Trains in order of their first release; "" (shared) first.
    let trains: [String]
    /// Oldest first.
    var releases: [Release]
    let loadedAt: Date
    var baseBranch: String = ""

    func releases(on train: String) -> [Release] { releases.filter { $0.train == train } }

    /// A release by its name or any of its build tags.
    func release(named tag: String) -> Release? {
        releases.first { $0.name == tag || $0.builds.contains { $0.tag == tag } }
            ?? releases.first { $0.name.lowercased() == tag.lowercased() || $0.shortName.lowercased() == tag.lowercased() }
    }

    func trainTitle(_ train: String) -> String { Self.trainTitle(train, among: trains) }

    static func trainTitle(_ train: String, among trains: [String]) -> String {
        if train.isEmpty { return trains.count > 1 ? "Shared" : "Releases" }
        return train.uppercased()
    }

    /// The build each train had live at `date`: its last tag before then, while its release's era lasts.
    func liveAt(_ date: Date) -> [(train: String, build: Build, release: Release)] {
        trains.compactMap { train in
            var found: (Build, Release)?
            for release in releases where release.train == train {
                for build in release.builds where build.date <= date {
                    if found == nil || build.date >= found!.0.date { found = (build, release) }
                }
            }
            guard let (build, release) = found else { return nil }
            // A train that handed over or went quiet has nothing live after its last era.
            let last = releases(on: train).last
            if release.id == last?.id, !release.isCurrent, date > release.end { return nil }
            return (train, build, release)
        }
    }

    /// Per train, the first release that shipped a ticket, a commit (sha prefix) or text.
    func firstContaining(_ text: String) -> [(train: String, release: Release, commit: ReleaseCommit?)] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let isSHA = query.count >= 6 && query.allSatisfy(\.isHexDigit)
        return trains.compactMap { train in
            for release in releases(on: train) {
                if let commit = release.newCommits.first(where: { commit in
                    isSHA ? commit.sha.hasPrefix(query) : commit.subject.lowercased().contains(query)
                }) {
                    return (train, release, commit)
                }
                if isSHA, release.builds.contains(where: { $0.commit.hasPrefix(query) }) { return (train, release, nil) }
            }
            return nil
        }
    }
}

// MARK: - Grouping

enum ReleaseGrouping {
    /// Groups tags into releases and trains and works out each release's era.
    /// `onBase` holds the tags whose commit is on the base branch.
    static func timeline(_ tags: [TagInfo], repository: RepositoryConfig, onBase: Set<String>, now: Date = .now) -> RepositoryTimeline {
        let scheme = repository.scheme
        var groups: [String: (train: String, release: String, builds: [Build])] = [:]
        for tag in tags {
            guard let parsed = scheme.parse(tag.name) else { continue }
            let build = Build(tag: tag.name, number: parsed.build, date: tag.date, commit: tag.commit, subject: tag.subject,
                              onBase: onBase.contains(tag.name))
            groups["\(parsed.train)|\(parsed.release)", default: (parsed.train, parsed.release, [])].builds.append(build)
        }
        var releases = groups.values.map { group in
            Release(repository: repository.id, name: group.release, train: group.train,
                    builds: group.builds.sorted { ($0.date, $0.number ?? 0) < ($1.date, $1.number ?? 0) })
        }
        releases.sort { ($0.start, $0.name) < ($1.start, $1.name) }
        let trains = trainOrder(releases)
        let idle = TimeInterval(max(1, repository.idleDays)) * 86_400
        var result: [Release] = []
        for train in trains {
            var list = releases.filter { $0.train == train }
            for index in list.indices {
                list[index].index = index
                list[index].trainCount = list.count
                list[index].previous = index > 0 ? list[index - 1].name : nil
                let quietFrom = list[index].lastBuild.date.addingTimeInterval(idle)
                if index + 1 < list.count {
                    let next = list[index + 1].start
                    list[index].end = min(next, quietFrom)
                    list[index].endReason = next <= quietFrom ? .next : .idle
                    list[index].next = next <= quietFrom ? list[index + 1].name : nil
                } else if train.isEmpty, now > quietFrom,
                          let handover = releases.first(where: { !$0.train.isEmpty && $0.start > list[index].start })?.start {
                    // The shared train stopped and named trains carry on (a split into regions).
                    list[index].end = min(handover, quietFrom)
                    list[index].endReason = handover < quietFrom ? .handover : .idle
                } else {
                    list[index].end = max(now, list[index].lastBuild.date)
                    list[index].endReason = .today
                }
            }
            result += list
        }
        result.sort { ($0.start, $0.name) < ($1.start, $1.name) }
        // What each release is compared with: the one before on its train, else (first of a new
        // train) the shared train's release live when it started.
        for index in result.indices {
            let release = result[index]
            if let previous = release.previous, let before = result.first(where: { $0.train == release.train && $0.name == previous }) {
                result[index].base = before.builds.last { $0.date <= release.start }?.tag ?? before.lastBuild.tag
            } else if !release.train.isEmpty {
                let shared = result.filter { $0.train.isEmpty }.flatMap(\.builds).filter { $0.date <= release.start }
                result[index].base = shared.max { $0.date < $1.date }?.tag
            }
        }
        return RepositoryTimeline(repository: repository, trains: trains, releases: result, loadedAt: now)
    }

    /// Shared first, then by first release.
    static func trainOrder(_ releases: [Release]) -> [String] {
        var trains: [String] = []
        for release in releases where !trains.contains(release.train) { trains.append(release.train) }
        return trains.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
            return trains.firstIndex(of: lhs)! < trains.firstIndex(of: rhs)!
        }
    }
}

// MARK: - Commit groups

enum CommitGroups {
    /// Dependency bumps and translations, whatever ticket they carry.
    static func isDependency(_ subject: String) -> Bool {
        subject.contains(/(?i)dependabot|chore\(deps\)|^bump |chore: bump|translations|lokalise|renovate/)
    }

    /// Commits grouped by ticket project ("LAF", "PPT"…), then "Other", then dependencies; newest first.
    static func group(_ commits: [ReleaseCommit]) -> [(title: String, commits: [ReleaseCommit])] {
        var groups: [String: [ReleaseCommit]] = [:]
        for commit in commits {
            let key: String
            if isDependency(commit.subject) { key = "~deps" }
            else if let ticket = commit.tickets.first { key = String(ticket.split(separator: "-")[0]) }
            else { key = "~other" }
            groups[key, default: []].append(commit)
        }
        return groups.keys.sorted { lhs, rhs in
            if lhs.hasPrefix("~") != rhs.hasPrefix("~") { return !lhs.hasPrefix("~") }
            if lhs.hasPrefix("~") { return lhs == "~other" }
            return (groups[lhs]!.count, rhs) > (groups[rhs]!.count, lhs)
        }.map { key in
            let title = key == "~deps" ? "Dependencies & translations" : key == "~other" ? "Other" : "\(key) changes"
            return (title, groups[key]!.sorted { $0.date > $1.date })
        }
    }
}

// MARK: - Events

/// A launch, incident or milestone shown on the events lane.
struct ReleaseEvent: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case launch, incident, milestone

        var title: String { rawValue.capitalized }
        var systemImage: String {
            switch self {
            case .launch: "circle.fill"
            case .incident: "triangle.fill"
            case .milestone: "diamond.fill"
            }
        }
    }

    var id: String = UUID().uuidString
    var date: Date
    var kind: Kind
    var title: String
    var note: String = ""
    /// A repository id; nil shows on every repository.
    var repository: String?
}

// MARK: - Dates

enum ReleaseDates {
    /// "2026-06-05" (the end of that day, or now for today) or an ISO 8601 moment.
    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(trimmed, strategy: .iso8601) { return date }
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        if calendar.isDate(day, inSameDayAs: now) { return now }
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: day)
    }

    static func day(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

    /// A date typed in the timeline's search, as noon that day: "2026-10-12", "12 Oct", "Oct 12",
    /// "12 October 2026", "12/10/2026", or an ISO week ("W41", "2026W41", "2026-W41", its Monday).
    /// Without a year, the latest such day not after `now`. nil when the text isn't a date.
    static func search(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.count <= 20 else { return nil }
        func noon(_ date: Date) -> Date { calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date }
        let year = calendar.component(.year, from: now)
        if let match = trimmed.wholeMatch(of: /(?i)(?:(\d{4})-?)?w(\d{1,2})/), let week = Int(match.2), (1...53).contains(week) {
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            func monday(_ year: Int) -> Date? { iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)) }
            if let given = match.1.flatMap({ Int($0) }) { return monday(given).map(noon) }
            guard let this = monday(iso.component(.yearForWeekOfYear, from: now)) else { return nil }
            return noon(this > now ? (monday(iso.component(.yearForWeekOfYear, from: now) - 1) ?? this) : this)
        }
        if let match = trimmed.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
           let date = calendar.date(from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))) {
            return noon(date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        for format in ["d MMM yyyy", "MMM d yyyy", "d MMMM yyyy", "MMMM d yyyy", "dd/MM/yyyy", "d/M/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed.replacingOccurrences(of: ",", with: "")) { return noon(date) }
        }
        for format in ["d MMM", "MMM d", "d MMMM", "MMMM d", "d/M"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: trimmed.replacingOccurrences(of: ",", with: "")) else { continue }
            var parts = calendar.dateComponents([.month, .day], from: parsed)
            parts.year = year
            guard var date = calendar.date(from: parts) else { continue }
            if date > now { date = calendar.date(byAdding: .year, value: -1, to: date) ?? date }
            return noon(date)
        }
        return nil
    }
}
