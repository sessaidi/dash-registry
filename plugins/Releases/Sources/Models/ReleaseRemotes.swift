import DashKit
import Foundation

/// Repositories from the GitHub and GitLab integrations: a widget can show one without the user
/// adding a folder. A local checkout of it is read with git when there is one; otherwise the
/// integration mirrors its tags and commit ranges into Dash (`host.synced`) and Releases reads that.
struct RemoteRepository: Hashable, Sendable, Identifiable {
    /// "github" or "gitlab".
    let service: String
    /// "owner/name" or "group/subgroup/project".
    let slug: String
    /// "github.com", "gitlab.example.com".
    let host: String

    var id: String { source }
    var source: String { "\(service):\(slug)" }
    var name: String { String(slug.split(separator: "/").last ?? Substring(slug)) }

    /// The integrations' watched repositories (their `exports`), GitHub first.
    @MainActor
    static func available(host: (any ExtensionContext)?) -> [RemoteRepository] {
        var result: [RemoteRepository] = []
        if let github = host?.integration("github")?.exports {
            let web = URL(string: github["webURL"]?.string ?? "https://github.com")?.host() ?? "github.com"
            result += (github["repos"]?.array ?? []).compactMap(\.string).map { RemoteRepository(service: "github", slug: $0, host: web) }
        }
        if let gitlab = host?.integration("gitlab")?.exports {
            let instance = URL(string: gitlab["instance"]?.string ?? "https://gitlab.com")?.host() ?? "gitlab.com"
            result += (gitlab["projects"]?.array ?? []).compactMap(\.string).map { RemoteRepository(service: "gitlab", slug: $0, host: instance) }
        }
        return result
    }

    /// A local checkout whose origin is this repository, if one exists under ~/code (three levels deep).
    func localCheckout(among checkouts: [String]) async -> String? {
        let wanted = slug.lowercased()
        for path in checkouts where (path as NSString).lastPathComponent.lowercased() == name.lowercased() {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            let origin = (try? await GitReader(directory: url).run(["remote", "get-url", "origin"]))?.lowercased() ?? ""
            if origin.contains(wanted) { return path }
        }
        return nil
    }
}

/// Where a timeline's tags and commits come from: git in a checkout, or the synced mirror.
protocol ReleaseSource: Sendable {
    func tags() async throws -> [TagInfo]
    func baseBranch(_ configured: String) async -> String?
    func tags(mergedInto branch: String) async throws -> Set<String>
    func commits(from base: String?, to head: String, limit: Int) async throws -> [ReleaseCommit]
    /// git marks cherry-picks by patch id; the mirror only has subjects, so the loader
    /// approximates them.
    var marksCherryPicks: Bool { get }
}

extension GitReader: ReleaseSource {
    var marksCherryPicks: Bool { true }
}

/// A repository read from the integration's mirror in Dash's synced store: tags as last synced,
/// commit ranges fetched through the integration on first use (they never change).
struct SyncedReleaseSource: ReleaseSource {
    let tagList: [TagInfo]
    let onBase: Set<String>
    let defaultBranch: String
    let range: @Sendable (_ base: String, _ head: String) async throws -> [ReleaseCommit]

    var marksCherryPicks: Bool { false }

    func tags() async throws -> [TagInfo] { tagList }

    func baseBranch(_ configured: String) async -> String? {
        let configured = configured.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? defaultBranch : configured
    }

    /// Whether each tag is on the default branch, as the integration found it.
    func tags(mergedInto branch: String) async throws -> Set<String> { onBase }

    func commits(from base: String?, to head: String, limit: Int) async throws -> [ReleaseCommit] {
        guard let base else { return [] }
        return Array(try await range(base, head).prefix(limit))
    }

    static let tagKind = "git.tag"
    static let rangeKind = "git.range"
    static let repoKind = "git.repo"

    /// Tags and their branch from the mirror's records.
    static func tags(_ records: [SyncedRecord]) -> (tags: [TagInfo], onBase: Set<String>) {
        var tags: [TagInfo] = []
        var onBase: Set<String> = []
        for record in records {
            guard let commit = record.value["commit"]?.string else { continue }
            tags.append(TagInfo(name: record.key, date: date(record.value["date"]?.string) ?? record.updatedAt, commit: commit,
                                subject: record.value["subject"]?.string ?? ""))
            if record.value["on_base"]?.bool != false { onBase.insert(record.key) }
        }
        return (tags, onBase)
    }

    /// Commits as the integrations return them: sha, author, date, subject.
    static func commits(_ value: JSONValue) -> [ReleaseCommit] {
        (value.array ?? []).compactMap { item in
            guard let sha = item["sha"]?.string else { return nil }
            return ReleaseCommit(sha: sha, author: item["author"]?.string ?? "", date: date(item["date"]?.string) ?? .distantPast,
                                 subject: item["subject"]?.string ?? "", alreadyShipped: false)
        }.sorted { $0.date > $1.date }
    }

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return (try? Date(text, strategy: .iso8601)) ?? ISO8601DateFormatter.fractional.date(from: text)
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
