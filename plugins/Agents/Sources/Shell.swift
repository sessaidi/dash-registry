import DashKit
import DashKitUI
import Foundation

struct ShellError: LocalizedError {
    let command: String
    let status: Int32
    let output: String
    var errorDescription: String? { "`\(command)` failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

enum Shell {
    /// GUI apps start with a minimal PATH; add the usual tool locations.
    static var environment: [String: String] {
        var environment = ShellEnvironment.current
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (extra + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])).joined(separator: ":")
        return environment
    }

    /// Finds an executable on the extended PATH.
    static func which(_ name: String) -> URL? {
        for directory in environment["PATH"]?.split(separator: ":") ?? [] {
            let url = URL(filePath: String(directory)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs a command to completion and returns stdout. Throws with stderr on failure.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) async throws -> String {
        guard let url = executable.hasPrefix("/") ? URL(filePath: executable) : which(executable) else {
            throw ShellError(command: executable, status: -1, output: "not found on PATH")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let command = ([executable] + arguments).joined(separator: " ")
                    continuation.resume(throwing: ShellError(command: command, status: process.terminationStatus, output: errors.isEmpty ? output : errors))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum Git {
    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await Shell.run("git", arguments, in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "origin/main" (falls back to origin/main when origin/HEAD is unset).
    static func remoteDefaultBranch(_ repo: URL) async -> String {
        (try? await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo)) ?? "origin/main"
    }

    /// owner/name parsed from the origin URL (ssh or https).
    static func gitHubSlug(_ repo: URL) async throws -> String {
        let remote = try await git(["remote", "get-url", "origin"], in: repo)
        return try slug(fromRemote: remote)
    }

    static func slug(fromRemote remote: String) throws -> String {
        var path = remote
        if let range = path.range(of: "github.com") { path = String(path[range.upperBound...]) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { throw ToolError("Origin \(remote) is not a GitHub repository.") }
        return parts.joined(separator: "/")
    }

    /// "kan-1234-add-retry-to-the-fetcher"
    static func branchName(key: String, summary: String) -> String {
        let words = summary.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var slug = key.lowercased()
        for word in words {
            guard slug.count + word.count + 1 <= 50 else { break }
            slug += "-" + word
        }
        return slug
    }
}
