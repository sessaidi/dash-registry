import DashKit
import Foundation

struct GitError: LocalizedError {
    let command: String
    let status: Int32
    let output: String
    var errorDescription: String? { "`git \(command)` failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// Read-only git commands in one checkout, run with your login shell's environment.
struct GitReader: Sendable {
    let directory: URL
    var environment: [String: String] = GitReader.environment

    /// GUI apps start with a minimal PATH; add the usual tool locations.
    static var environment: [String: String] {
        var environment = ShellEnvironment.current
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = ((environment["PATH"]?.split(separator: ":").map(String.init) ?? []) + extra).joined(separator: ":")
        // Never wait for a credential prompt or a pager.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        return environment
    }

    static var executable: URL? {
        for directory in environment["PATH"]?.split(separator: ":") ?? [] {
            let url = URL(filePath: String(directory)).appending(path: "git")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs git to completion off the main thread and returns stdout. Pipes are drained while
    /// it runs, so large outputs can't block it.
    func run(_ arguments: [String]) async throws -> String {
        guard let git = Self.executable else { throw ToolError("git isn't installed (not found on PATH).") }
        let directory = directory
        let environment = environment
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = git
                process.arguments = ["--no-optional-locks"] + arguments
                process.environment = environment
                process.currentDirectoryURL = directory
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let errors = Collected()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: output, as: UTF8.self))
                } else {
                    continuation.resume(throwing: GitError(command: arguments.joined(separator: " "), status: process.terminationStatus,
                                                           output: String(decoding: errors.data, as: UTF8.self)))
                }
            }
        }
    }

    private final class Collected: @unchecked Sendable { var data = Data() }

    // MARK: Queries

    static let unit = "\u{1f}"
    static let record = "\u{1e}"

    /// Every tag with its date (creator date: the tagger's, or the commit's for lightweight tags),
    /// tagged commit and subject.
    func tags() async throws -> [TagInfo] {
        let output = try await run(["for-each-ref", "--format=%(refname:strip=2)%1f%(creatordate:unix)%1f%(objectname)%1f%(*objectname)%1f%(subject)%1e", "refs/tags"])
        return Self.parseTags(output)
    }

    static func parseTags(_ output: String) -> [TagInfo] {
        output.components(separatedBy: record).compactMap { line in
            let fields = line.trimmingCharacters(in: .newlines).components(separatedBy: unit)
            guard fields.count >= 5, !fields[0].isEmpty, let seconds = TimeInterval(fields[1]) else { return nil }
            return TagInfo(name: fields[0], date: Date(timeIntervalSince1970: seconds), commit: fields[3].isEmpty ? fields[2] : fields[3],
                           subject: fields[4...].joined(separator: unit))
        }
    }

    /// The configured base branch, else origin's HEAD, else main or master.
    func baseBranch(_ configured: String) async -> String? {
        let configured = configured.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        if let head = try? await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !head.isEmpty {
            return head
        }
        for candidate in ["origin/main", "main", "origin/master", "master"] where (try? await run(["rev-parse", "--verify", "--quiet", candidate])) != nil {
            return candidate
        }
        return nil
    }

    /// Tags whose commit is on `branch` (same answer as `merge-base --is-ancestor` per tag, in one call).
    func tags(mergedInto branch: String) async throws -> Set<String> {
        let output = try await run(["for-each-ref", "--merged=\(branch)", "--format=%(refname:strip=2)", "refs/tags"])
        return Set(output.split(separator: "\n").map(String.init))
    }

    /// Commits in `head` but not in `base`, without merges. Changes `base` already has as a
    /// cherry-pick (same patch id) are marked `alreadyShipped`. At most `limit`, newest first.
    func commits(from base: String?, to head: String, limit: Int = 1_000) async throws -> [ReleaseCommit] {
        let range = base.map { ["\($0)...\(head)", "--right-only", "--cherry-mark"] } ?? [head]
        let output = try await run(["log", "--no-merges", "--max-count=\(limit)", "--format=%m%x1f%H%x1f%an%x1f%at%x1f%s%x1e"] + range)
        return Self.parseCommits(output)
    }

    static func parseCommits(_ output: String) -> [ReleaseCommit] {
        output.components(separatedBy: record).compactMap { line in
            let fields = line.trimmingCharacters(in: .newlines).components(separatedBy: unit)
            guard fields.count >= 5, let seconds = TimeInterval(fields[3]) else { return nil }
            return ReleaseCommit(sha: fields[1], author: fields[2], date: Date(timeIntervalSince1970: seconds),
                                 subject: fields[4...].joined(separator: unit), alreadyShipped: fields[0] == "=")
        }
    }

    /// Whether `commit` is in `head`'s history.
    func isAncestor(_ commit: String, of head: String) async -> Bool {
        (try? await run(["merge-base", "--is-ancestor", commit, head])) != nil
    }

    func resolve(_ revision: String) async -> String? {
        try? await run(["rev-parse", "--verify", "--quiet", revision + "^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Loading

/// Turns a checkout's tags into a timeline. Commit ranges are cached by (base, head) commits,
/// which never change, so a refresh only asks git about new tags. With a `cacheFile` the cache
/// survives relaunches (the first read of a big repository takes a while).
actor ReleaseLoader {
    private var ranges: [String: [ReleaseCommit]] = [:]
    private var restored = false
    /// How many `git log` calls run at once.
    let width: Int
    let cacheFile: URL?

    init(width: Int = 6, cacheFile: URL? = nil) {
        self.width = width
        self.cacheFile = cacheFile
    }

    /// ~/Library/Caches/Dash/releases-ranges.json
    static var defaultCacheFile: URL { URL.cachesDirectory.appending(path: "Dash/releases-ranges.json") }

    private func restore() {
        guard !restored else { return }
        restored = true
        guard let cacheFile, let data = try? Data(contentsOf: cacheFile),
              let saved = try? JSONDecoder().decode([String: [ReleaseCommit]].self, from: data) else { return }
        ranges.merge(saved) { current, _ in current }
    }

    private func persist() {
        guard let cacheFile, let data = try? JSONEncoder().encode(ranges) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }

    var cachedRanges: Int { ranges.count }

    /// Reads a timeline from `source`, or with git in the repository's checkout when nil.
    func load(_ repository: RepositoryConfig, now: Date = .now, source: (any ReleaseSource)? = nil) async throws -> RepositoryTimeline {
        let git: any ReleaseSource
        if let source {
            git = source
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: repository.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolError("\(repository.path) doesn't exist.")
            }
            git = GitReader(directory: repository.url)
        }
        let tags = try await git.tags()
        let base = await git.baseBranch(repository.baseBranch)
        // No base branch found: nothing counts as a hotfix.
        var onBase = Set(tags.map(\.name))
        if let base { onBase = try await git.tags(mergedInto: base) }
        var timeline = ReleaseGrouping.timeline(tags, repository: repository, onBase: onBase, now: now)
        timeline.baseBranch = base ?? ""
        try await fillCommits(&timeline, git: git)
        return timeline
    }

    /// One range per build: the release's base to its first build, then build to build.
    private func fillCommits(_ timeline: inout RepositoryTimeline, git: any ReleaseSource) async throws {
        restore()
        let commitOf = Dictionary(timeline.releases.flatMap(\.builds).map { ($0.tag, $0.commit) }, uniquingKeysWith: { first, _ in first })
        var jobs: [(key: String, base: String?, head: String)] = []
        for release in timeline.releases {
            guard let base = release.base.flatMap({ commitOf[$0] }) else { continue }
            var from = base
            for build in release.builds {
                let key = from + ".." + build.commit
                if ranges[key] == nil, !jobs.contains(where: { $0.key == key }) { jobs.append((key, from, build.commit)) }
                from = build.commit
            }
        }
        let width = width
        try await withThrowingTaskGroup(of: (String, [ReleaseCommit]).self) { group in
            var pending = jobs[...]
            for _ in 0..<min(width, pending.count) {
                let job = pending.removeFirst()
                group.addTask { (job.key, try await git.commits(from: job.base, to: job.head, limit: 1_000)) }
            }
            while let (key, commits) = try await group.next() {
                ranges[key] = commits
                if let job = pending.popFirst() {
                    group.addTask { (job.key, try await git.commits(from: job.base, to: job.head, limit: 1_000)) }
                }
            }
        }
        if !jobs.isEmpty { persist() }
        for index in timeline.releases.indices {
            let release = timeline.releases[index]
            guard let base = release.base.flatMap({ commitOf[$0] }) else { continue }
            var from = base
            var commits: [ReleaseCommit] = []
            var seen: Set<String> = []
            for build in release.builds {
                for var commit in ranges[from + ".." + build.commit] ?? [] where seen.insert(commit.sha).inserted {
                    commit.build = build.tag
                    commits.append(commit)
                }
                if (ranges[from + ".." + build.commit]?.count ?? 0) >= 1_000 { timeline.releases[index].commitsTruncated = true }
                from = build.commit
            }
            timeline.releases[index].commits = commits.sorted { $0.date > $1.date }
        }
        if !git.marksCherryPicks { Self.markCherryPicks(&timeline) }
    }

    /// Without patch ids: a commit counts as already shipped when the release it's compared with
    /// had a commit with the same subject.
    static func markCherryPicks(_ timeline: inout RepositoryTimeline) {
        var releaseOf: [String: Int] = [:]
        for (index, release) in timeline.releases.enumerated() { for build in release.builds { releaseOf[build.tag] = index } }
        let subjects = timeline.releases.map { Set($0.commits.map(\.subject)) }
        for index in timeline.releases.indices {
            guard let base = timeline.releases[index].base, let baseIndex = releaseOf[base], baseIndex != index else { continue }
            for commit in timeline.releases[index].commits.indices where subjects[baseIndex].contains(timeline.releases[index].commits[commit].subject) {
                timeline.releases[index].commits[commit].alreadyShipped = true
            }
        }
    }

    /// The tag scheme a checkout's tags most likely follow.
    static func guessScheme(_ directory: URL) async -> TagScheme? {
        guard let tags = try? await GitReader(directory: directory).tags() else { return nil }
        return TagScheme.guess(tags.map(\.name))
    }
}
