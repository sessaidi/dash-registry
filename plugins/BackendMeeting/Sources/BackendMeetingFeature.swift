import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftData
import SwiftUI

/// The backend meeting report: what you shipped and what's in progress over a cycle (1–10 weeks,
/// by default since the last report), as a few themed bullets. Built from your GitHub PRs, your
/// Jira tickets and Dash's activity; everything remote is only read.
@MainActor
@Observable
final class BackendMeetingFeature: DashExtension {
    let id = "backend-meeting"
    let name = "Backend Meeting"
    let systemImage = "person.2.wave.2"
    let metadata = ExtensionMetadata(
        version: "1.0.0", author: .dash,
        summary: "Your highlights for the backend meeting: PRs, tickets and activity over a cycle, grouped into themes.",
        category: .productivity, tags: ["meeting", "report", "highlights", "fait marquant"], homepage: "https://github.com/sessaidi/dash",
        minimumDashKit: "1.5.0")
    /// PRs come from GitHub; Jira tickets are added when Atlassian is connected.
    let requires = ["github"]
    let optional = ["atlassian"]

    /// The cycle new widgets start with, in weeks (1–10).
    var defaultCycleWeeks: Int { didSet { defaults.set(defaultCycleWeeks, forKey: "backend-meeting.cycleWeeks") } }
    /// Where each report is also written as markdown; empty writes nothing.
    var outputFolder: String { didSet { defaults.set(outputFolder, forKey: "backend-meeting.outputFolder") } }

    /// What's happening while a report is generated ("Reading your pull requests…"), nil when idle.
    private(set) var progress: String?
    private(set) var lastError: String?
    /// Bumped when reports change, for views.
    private(set) var revision = 0

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        defaultCycleWeeks = min(max(defaults.object(forKey: "backend-meeting.cycleWeeks") as? Int ?? 2, 1), 10)
        outputFolder = defaults.string(forKey: "backend-meeting.outputFolder") ?? "~/code/meeting/backend"
    }

    var models: [any PersistentModel.Type] { [BackendReport.self] }
    var widgets: [WidgetType] { [WidgetType(BackendMeetingWidget.self)] }
    func settingsView() -> AnyView { AnyView(BackendMeetingSettings(feature: self)) }

    func start(host: any ExtensionContext) {
        self.host = host
    }

    // MARK: Reports

    func reports(limit: Int = 50) -> [BackendReport] {
        var descriptor = FetchDescriptor<BackendReport>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? host?.context.fetch(descriptor)) ?? []
    }

    func report(_ id: UUID) -> BackendReport? {
        try? host?.context.fetch(FetchDescriptor<BackendReport>(predicate: #Predicate { $0.id == id })).first
    }

    /// The range the next report covers.
    func nextRange(cycleWeeks: Int, sinceLastReport: Bool, now: Date = .now) -> ReportRange {
        ReportRange.make(cycleWeeks: cycleWeeks, sinceLastReport: sinceLastReport, lastEnd: reports(limit: 1).first?.end, now: now)
    }

    static let reportTask = AITask(
        id: "report", title: "Backend meeting report",
        summary: "Groups your PRs, tickets and activity over the cycle into a few themed highlights.",
        models: [.balanced, .strong, .fast], defaultModel: .balanced, efforts: [.low, .medium, .high], defaultEffort: .medium,
        templates: [AITemplate(id: "language", title: "Language", defaultText: "English")])

    var aiTasks: [AITask] { [Self.reportTask] }
    var ai: AISettings { host?.aiSettings(.extension(id), tasks: aiTasks) ?? AISettings(tasks: aiTasks) }

    /// The fait-marquant rules: themes from shipped work, "In chantier" for what's in flight,
    /// a bare "Debug & Fix" for small fixes, no ids, links or dates.
    static func systemPrompt(language: String) -> String {
        """
        You write the user's highlights ("fait marquant") for their backend team meeting, from their GitHub pull requests, \
        Jira tickets and Dash activity over the cycle. Answer with only a markdown bullet list, in \(language).

        Grouping:
        - Build themes from merged PRs first: they are the shipped work. PRs whose titles share a ticket key are one theme, \
        even across repositories. Tickets repeated across PRs are a real chantier, not a chore.
        - A theme gets its own bullet when several PRs across repositories share a ticket, when one PR is a substantial \
        feature or integration, or when a ticket keeps coming back. Never make a theme of one trivial PR (chore, version bump, typo).
        - Open or draft PRs at the end of the cycle, and tickets in progress or in review, go under "In chantier". \
        Only real ongoing work: no stale drafts or abandoned branches.
        - Standalone UX/UI fixes, hotfixes, prod bug investigations, small observability tweaks and chores that shipped go under \
        "Debug & Fix", only when there are at least two of them; one alone is folded into the closest theme or dropped.
        - PRs closed without merge are not work done: ignore them.

        Format:
        - Each theme: `- **Theme name**: one factual line of what the work does`. Name the theme by what the work does, \
        not by ticket numbers or repository names.
        - Then `- **In chantier**:` with one nested sub-bullet per chantier (two-space indent, even when there is only one), \
        omitted when nothing is in flight.
        - Then `- **Debug & Fix**` alone, with no description and no sub-bullets, only when warranted.
        - Shipped themes first, then In chantier, then Debug & Fix.
        - No ticket ids, no PR numbers or links, no dates in the bullets. No heading, no closing paragraph.
        """
    }

    /// Generates (and stores) the report for a range: reads the data, asks Claude, saves it to
    /// the database and, when a folder is set, as markdown.
    @discardableResult
    func generate(range: ReportRange, cycleWeeks: Int) async throws -> BackendReport {
        guard let host else { throw ToolError("Backend Meeting isn't running.") }
        guard progress == nil else { throw ToolError("A report is already being written.") }
        defer { progress = nil }
        do {
            let data = try await evidence(range: range)
            progress = "Writing the report…"
            let text = try await host.dashii.complete(
                task: Self.reportTask.id, settings: ai,
                system: Self.systemPrompt(language: ai.render(Self.reportTask.id, "language", [:])),
                prompt: data.jsonString())
            let markdown = Self.clean(text)
            let report = BackendReport(start: range.start, end: range.end, cycleWeeks: cycleWeeks, markdown: markdown)
            host.context.insert(report)
            try? host.context.save()
            writeFile(report)
            // Every report also lands in Notes, next to the other generated reports.
            _ = try? host.createNote(title: "Backend Meeting \(range.startDay) → \(range.endDay)",
                                     markdown: "# Backend Meeting \(range.startDay) → \(range.endDay)\n\n" + markdown, folder: "Reports")
            lastError = nil
            revision += 1
            host.emit("backend-meeting.report", from: self, title: "Backend meeting report ready (\(range.label))", detail: markdown, importance: .notable)
            return report
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func delete(_ report: BackendReport) {
        host?.context.delete(report)
        try? host?.context.save()
        revision += 1
    }

    /// Drops a code fence or heading Claude may wrap the list in.
    static func clean(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("```") && !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<folder>/fait-marquant-<start>-to-<end>.md`, overwritten when the range is regenerated.
    func fileURL(for report: BackendReport) -> URL? {
        let folder = outputFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { return nil }
        let range = ReportRange(start: report.start, end: report.end)
        return URL(filePath: (folder as NSString).expandingTildeInPath).appending(path: "fait-marquant-\(range.startDay)-to-\(range.endDay).md")
    }

    private func writeFile(_ report: BackendReport) {
        guard let url = fileURL(for: report) else { return }
        let range = ReportRange(start: report.start, end: report.end)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# Fait marquant — \(range.startDay) → \(range.endDay)\n\n\(report.markdown)\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DashLog.error("Couldn't write \(url.path): \(error.localizedDescription)", category: id)
        }
    }

    // MARK: Data (read-only)

    /// Everything the report is built from, for Claude.
    func evidence(range: ReportRange) async throws -> JSONValue {
        progress = "Reading your pull requests…"
        let pulls = try await pullRequests(range: range)
        var result: [String: JSONValue] = [
            "cycle": ["start": .string(range.startDay), "end": .string(range.endDay)],
            "pull_requests": .array(pulls.filter { $0.state != .closed }.map(\.json)),
        ]
        if host?.integration("atlassian")?.connection != nil {
            progress = "Reading your Jira tickets…"
            do {
                result["tickets"] = .array(try await tickets(range: range))
            } catch {
                DashLog.error("Jira tickets unavailable: \(error.localizedDescription)", category: id)
            }
        }
        if let host {
            result["dash_activity"] = .array(host.activity.events(since: range.start, minimum: .notable).filter { $0.date <= range.end && $0.source != id }
                .suffix(120).map { ["kind": .string($0.kind), "title": .string($0.title), "source": .string($0.source)] })
        }
        return .object(result)
    }

    /// The user's PRs updated in the range, across their organisations and personal repositories.
    func pullRequests(range: ReportRange) async throws -> [AuthoredPull] {
        guard let github = host?.integration("github"), let connection = github.connection else { throw ToolError("Connect GitHub first.") }
        var login = github.exports["login"]?.string ?? ""
        if login.isEmpty { login = try await connection.get("/user", service: "GitHub")["login"]?.string ?? "" }
        guard !login.isEmpty else { throw ToolError("Couldn't tell who you are on GitHub.") }
        let orgs = ((try? await connection.get("/user/orgs?per_page=100", service: "GitHub"))?.array ?? []).compactMap { $0["login"]?.string }
        let base = "author:\(login) is:pr updated:\(range.startDay)..\(range.endDay)"
        var seen = Set<String>()
        var result: [AuthoredPull] = []
        // The org-less query catches personal repositories; per-org queries catch org repositories it can miss.
        for query in [base] + orgs.map({ "\(base) org:\($0)" }) {
            for item in try await search(query, connection: connection) {
                guard let pull = AuthoredPull(item: item), seen.insert(pull.url).inserted else { continue }
                result.append(pull)
            }
        }
        return result.sorted { $0.updated > $1.updated }
    }

    private func search(_ query: String, connection: IntegrationConnection) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        for page in 1...5 {
            guard var components = connection.url("/search/issues").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { break }
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            guard let url = components.url else { break }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await connection.send(request, service: "GitHub")
            let batch = try JSONValue.parse(data)["items"]?.array ?? []
            items += batch
            if batch.count < 100 { break }
        }
        return items
    }

    static func ticketsJQL(range: ReportRange) -> String {
        let after = Calendar.current.date(byAdding: .day, value: 1, to: range.end) ?? range.end
        return "assignee = currentUser() AND updated >= \"\(range.startDay)\" AND updated < \"\(ReportRange.day(after))\" ORDER BY updated DESC"
    }

    /// Jira issues assigned to the user and updated in the range (GET search, read-only).
    func tickets(range: ReportRange) async throws -> [JSONValue] {
        guard let connection = host?.integration("atlassian")?.connection,
              var components = connection.url("/rest/api/3/search/jql").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "jql", value: Self.ticketsJQL(range: range)),
            URLQueryItem(name: "fields", value: "summary,status,issuetype,priority,project,resolutiondate"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await connection.send(request, service: "Jira")
        return (try JSONValue.parse(data)["issues"]?.array ?? []).map { issue in
            let fields = issue["fields"]
            return ["key": issue["key"] ?? .null, "summary": fields?["summary"] ?? .null,
                    "status": fields?["status"]?["name"] ?? .null, "status_category": fields?["status"]?["statusCategory"]?["key"] ?? .null,
                    "type": fields?["issuetype"]?["name"] ?? .null, "project": fields?["project"]?["name"] ?? .null,
                    "resolved": fields?["resolutiondate"] ?? .null]
        }
    }

    // MARK: Claude tools (read-only)

    var tools: [DashiiTool] {
        [DashiiTool(name: "backend_meeting_reports",
                    description: "The user's past backend meeting reports (highlights per cycle), newest first, with their date ranges.",
                    properties: ["limit": JSONSchema.integer("How many (default 3).")]) { [weak self] input in
            guard let self else { return nil }
            let limit = min(max(input["limit"]?.int ?? 3, 1), 20)
            return .array(reports(limit: limit).map {
                ["start": .string(ReportRange.day($0.start)), "end": .string(ReportRange.day($0.end)), "markdown": .string($0.markdown)]
            })
        }]
    }
}

struct BackendMeetingSettings: View {
    @Bindable var feature: BackendMeetingFeature

    var body: some View {
        Form {
            Section {
                Picker("Default cycle", selection: $feature.defaultCycleWeeks) {
                    ForEach(1...10, id: \.self) { Text($0 == 1 ? "1 week" : "\($0) weeks").tag($0) }
                }
                TextField("Also save reports in", text: $feature.outputFolder, prompt: Text("Leave empty to keep them only in Dash"))
            } header: {
                Text("Reports")
            } footer: {
                Text("A report covers the time since the previous one (or the cycle when there's none). It reads your GitHub PRs, your Jira tickets and Dash's activity; nothing is written to GitHub or Jira.")
            }
        }
        .formStyle(.grouped)
    }
}
