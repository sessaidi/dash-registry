import Foundation

/// Your commits in the clones under the code folder (worktrees share their clone's history).
enum StandupGit {
    struct Commit: Sendable, Hashable {
        let repo: String
        let sha: String
        let subject: String
        let at: Date
        let branch: String
    }

    static func commits(root: String, email: String, since: Date) -> [Commit] {
        let folder = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        let clones = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
        var result: [Commit] = []
        for clone in clones {
            let author = email.isEmpty ? (git(clone, ["config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : email
            guard !author.isEmpty,
                  let log = git(clone, ["log", "--all", "--no-merges", "--author=\(author)", "--since=\(ISO8601DateFormatter().string(from: since))",
                                        "--format=%h%x1f%ct%x1f%s%x1f%D"]) else { continue }
            for line in log.split(separator: "\n") {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3, let seconds = Double(parts[1]) else { continue }
                let branch = parts.count > 3 ? (parts[3].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "HEAD -> ", with: "") } ?? "") : ""
                result.append(Commit(repo: clone.lastPathComponent, sha: parts[0], subject: parts[2], at: Date(timeIntervalSince1970: seconds), branch: branch))
            }
        }
        return result.sorted { $0.at > $1.at }
    }

    static func git(_ folder: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
