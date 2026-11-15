import Foundation

/// A throwaway git repository built by the test: commits and tags at chosen dates.
final class TempRepo {
    let url: URL
    /// Every date is days after this (2026-01-05 12:00 UTC, a Monday).
    static let origin = Date(timeIntervalSince1970: 1_767_614_400)

    static func day(_ days: Double) -> Date { origin.addingTimeInterval(days * 86_400) }

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "releases-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Runs git with no user or system config (no signing, no hooks), at `date` when given.
    @discardableResult
    func git(_ arguments: String..., date: Date? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Tester", "-c", "user.email=tester@example.com", "-c", "commit.gpgsign=false",
                             "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = url
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            environment["GIT_AUTHOR_DATE"] = stamp
            environment["GIT_COMMITTER_DATE"] = stamp
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments): \(text)"]) }
        return text
    }

    /// Writes `content` to `file` and commits it; returns the sha.
    @discardableResult
    func commit(_ message: String, file: String, content: String, day: Double) throws -> String {
        try content.write(to: url.appending(path: file), atomically: true, encoding: .utf8)
        try git("add", file)
        try git("commit", "-q", "-m", message, date: Self.day(day))
        return try git("rev-parse", "HEAD")
    }

    /// An annotated tag on HEAD, dated `day`.
    func tag(_ name: String, day: Double) throws {
        try git("tag", "-a", name, "-m", name, date: Self.day(day))
    }

    /// The shared scenario: a shared train that splits into eu and us, a hotfix build on a
    /// branch, and the same fix later on main (a cherry-pick by patch).
    ///
    ///     day 0   c1 BILL-1   release-2026W02-01.01            (shared)
    ///     day 7   c2 KAN-10   release-2026W03-01.01            (shared, last)
    ///     day 14  c3 PPT-5    release-2026W04-01-eu.01, day 15 release-2026W04-02-us.01
    ///     day 16  h1 KAN-20   (branch hotfix) release-2026W04-01-eu.02
    ///     day 17  m1 KAN-20   (main, same patch as h1)
    ///     day 18  m2 KAN-21   release-2026W05-01-eu.01 (day 21), release-2026W06-02-us.01 (day 30)
    static func scenario() throws -> (repo: TempRepo, shas: [String: String]) {
        let repo = try TempRepo()
        var shas: [String: String] = [:]
        shas["c1"] = try repo.commit("BILL-1: first", file: "a.txt", content: "1\n", day: 0)
        try repo.tag("release-2026W02-01.01", day: 0)
        shas["c2"] = try repo.commit("KAN-10: second", file: "a.txt", content: "1\n2\n", day: 7)
        try repo.tag("release-2026W03-01.01", day: 7)
        shas["c3"] = try repo.commit("PPT-5: third", file: "a.txt", content: "1\n2\n3\n", day: 14)
        try repo.tag("release-2026W04-01-eu.01", day: 14)
        try repo.tag("release-2026W04-02-us.01", day: 15)
        try repo.git("checkout", "-q", "-b", "hotfix")
        shas["h1"] = try repo.commit("KAN-20: urgent fix", file: "fix.txt", content: "fix\n", day: 16)
        try repo.tag("release-2026W04-01-eu.02", day: 16)
        try repo.git("checkout", "-q", "main")
        shas["m1"] = try repo.commit("KAN-20: urgent fix", file: "fix.txt", content: "fix\n", day: 17)
        shas["m2"] = try repo.commit("KAN-21: next feature", file: "b.txt", content: "b\n", day: 18)
        try repo.tag("release-2026W05-01-eu.01", day: 21)
        try repo.tag("release-2026W06-02-us.01", day: 30)
        // Not a release tag: ignored.
        try repo.tag("deploy-test", day: 30)
        return (repo, shas)
    }
}
