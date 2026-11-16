import DashKit
import DashKitUI
import AppKit
import ClaudeCodeKit
import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AgentsExtension: DashExtension {
    let id = "agents"
    let name = "Agents"
    let systemImage = "hammer"
    let metadata = ExtensionMetadata(version: "1.10.0", summary: "Dashii agents working on Jira tickets with extreme TDD.", category: .ai, homepage: "https://github.com/sessaidi/dash")
    /// Tickets come from Jira; GitHub is only needed to open a PR, which the user confirms.
    let requires = ["atlassian"]
    let optional = ["github"]

    /// Path to the `claude` CLI; empty means Dash's own Claude Code setting, then PATH.
    var claudePath: String { didSet { defaults.set(claudePath, forKey: "agents.claudePath") } }
    /// Where clones live (`<codeRoot>/<repo>`); worktrees go in `<clone>/.worktrees/<name>`.
    var codeRoot: String { didSet { defaults.set(codeRoot, forKey: "agents.codeRoot") } }
    /// "PROJ=/path/to/repo" lines mapping Jira project keys to local clones.
    var repoMapText: String { didSet { defaults.set(repoMapText, forKey: "agents.repoMap") } }
    var implementPermissionMode: String { didSet { defaults.set(implementPermissionMode, forKey: "agents.permissionMode") } }
    /// Tools pre-approved while implementing, e.g. the test runner.
    var allowedToolsText: String { didSet { defaults.set(allowedToolsText, forKey: "agents.allowedTools") } }
    var model: String { didSet { defaults.set(model, forKey: "agents.model") } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    /// Agents with a turn in progress.
    private(set) var running: Set<UUID> = []
    /// One live Claude Code process per agent session, kept between turns.
    @ObservationIgnored private var processes: [UUID: ClaudeCodeSession] = [:]
    /// Last cumulative cost reported by each process, to add only the delta.
    @ObservationIgnored private var reportedCost: [UUID: Double] = [:]
    /// Every worktree on this Mac with its state and pull request.
    @ObservationIgnored let worktrees: WorktreeStore
    @ObservationIgnored private var worktreeLoop: Task<Void, Never>?

    static let defaultAllowedTools = "Bash(git status:*) Bash(git diff:*) Bash(git add:*) Bash(git commit:*) Bash(git log:*) Bash(make:*) Bash(go test:*) Bash(go build:*) Bash(go vet:*) Bash(npm test:*) Bash(npm run:*) Bash(pnpm:*) Bash(yarn:*) Bash(pytest:*) Bash(swift test:*) Bash(swift build:*) Bash(cargo test:*) Bash(cargo build:*)"

    /// Dash's app-wide Claude Code CLI path (Settings › Claude), written by the app as `claudePath`.
    static let appClaudePathKey = "claudePath"

    static let tddPrompt = """
        Dash runs you on a Jira ticket in a dedicated git worktree. The user is the sole author of every commit: \
        never add Co-Authored-By or other attribution trailers, nor "Generated with" lines, and don't change the author. \
        Never write anything remotely: no pushes, no comments or reviews on pull requests or issues, no API calls that change \
        GitHub or GitLab. Everything you produce stays in this worktree for the user to review.
        Follow extreme TDD strictly:
        1. Red: write one small failing test for the next behaviour. Run it and confirm it fails for the expected reason before writing any production code.
        2. Green: write the minimum production code that makes that test pass. Run the tests.
        3. Refactor with every test green, then run the tests again.
        4. Commit: one small commit per green step with a conventional message (test:, feat:, fix:, refactor:).
        Never write production code without a failing test that requires it. Never weaken, skip or delete a test to make it pass. \
        After each step, state the test command you ran and its result.
        Do not push, open pull requests, or change git remotes; Dash does that after the user reviews the branch.
        """

    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        worktrees = WorktreeStore(defaults: defaults)
        claudePath = defaults.string(forKey: "agents.claudePath") ?? ""
        codeRoot = defaults.string(forKey: "agents.codeRoot") ?? "~/Codes"
        repoMapText = defaults.string(forKey: "agents.repoMap") ?? ""
        implementPermissionMode = defaults.string(forKey: "agents.permissionMode") ?? "acceptEdits"
        allowedToolsText = defaults.string(forKey: "agents.allowedTools") ?? Self.defaultAllowedTools
        model = defaults.string(forKey: "agents.model") ?? ""
    }

    var models: [any PersistentModel.Type] { [AgentSession.self, AgentMessage.self, PullRequestTemplate.self] }
    var widgets: [WidgetType] { [WidgetType(AgentsWidget.self), WidgetType(WorktreesWidget.self)] }
    func settingsView() -> AnyView { AnyView(AgentsSettingsView(agents: self)) }

    func start(host: any ExtensionContext) {
        self.host = host
        // Processes don't survive a relaunch.
        for session in (try? host.context.fetch(FetchDescriptor<AgentSession>(predicate: #Predicate { $0.status == "running" }))) ?? [] {
            session.status = "idle"
        }
        try? host.context.save()
        // Worktrees: rescanned every 5 minutes (local git; remotes fetched every 30).
        worktreeLoop?.cancel()
        worktreeLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshWorktrees()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        for process in processes.values { process.terminate() }
        worktreeLoop?.cancel()
        worktreeLoop = nil
    }

    func refreshWorktrees() async {
        await worktrees.refresh(codeRoot: codeRoot, repositories: Array(repoMap.values), host: host)
    }

    var repoMap: [String: String] {
        Dictionary(repoMapText.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0].uppercased(), parts[1])
        }, uniquingKeysWith: { _, last in last })
    }

    private var permissionMode: PermissionMode {
        PermissionMode(rawValue: implementPermissionMode) ?? .acceptEdits
    }

    /// This extension's path, else Dash's Claude Code path; nil lets ClaudeCodeKit search PATH.
    var claudeExecutable: URL? {
        Self.executable(own: claudePath, app: defaults.string(forKey: Self.appClaudePathKey))
    }

    static func executable(own: String, app: String?) -> URL? {
        let path = own.isEmpty ? (app ?? "") : own
        return path.isEmpty ? nil : URL(filePath: (path as NSString).expandingTildeInPath)
    }

    func session(_ id: UUID) -> AgentSession? {
        try? host?.context.fetch(FetchDescriptor<AgentSession>(predicate: #Predicate { $0.id == id })).first
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Shows an agent's chat window (Dash's own "agent" window scene isn't available to plugins).
    func openWindow(_ sessionID: UUID) {
        guard let host else { return }
        AgentWindows.shared.open(sessionID: sessionID, agents: self, host: host)
    }

    // MARK: Prompts

    static func planPrompt(key: String, summary: String, ticket: String, branch: String, base: String) -> String {
        """
        You are working on Jira ticket \(key): \(summary)

        <ticket>
        \(ticket)
        </ticket>

        You are in a git worktree on branch \(branch), created from \(base). Read the relevant code, then \
        propose an implementation plan as a list of small behaviours, each with the test you will write \
        first for it. Ask me about anything ambiguous. Don't edit files yet; we'll agree the plan first.
        """
    }

    static let implementPrompt = """
        The plan is agreed. Implement it now with the extreme TDD loop: one failing test, minimum code to \
        pass, refactor, commit, repeat. When every behaviour is done, run the full test suite and finish with \
        a short summary I can use as the PR description.
        """

    /// The ticket as JSON for the prompt, or a minimal stand-in when Jira wasn't reachable.
    static func ticketText(detail: JSONValue?, key: String, summary: String) -> String {
        detail?.jsonString(pretty: true) ?? "{\"key\": \"\(key)\", \"summary\": \"\(summary)\"}"
    }

    static func pullRequestTitle(issueKey: String, title: String) -> String { "[\(issueKey)] \(title)" }

    static func pullRequestBody(issueKey: String, ticketURL: URL?, summary: String) -> String {
        [ticketURL.map { "Jira: [\(issueKey)](\($0))" } ?? "Jira: \(issueKey)", "", summary].joined(separator: "\n")
    }

    // MARK: AI settings

    static let agentTask = AITask(
        id: "agent", title: "Coding agent",
        summary: "The Dashii session that plans with you, then implements with extreme TDD in the ticket's worktree.",
        models: [.strong, .deep, .balanced], defaultModel: .strong, efforts: [.high, .xhigh, .max, .medium], defaultEffort: .high)

    static let pullRequestTask = AITask(
        id: "pull-request", title: "Opening pull requests",
        summary: "When the agent is done, Dash drafts the PR from these templates (a repository can have its own in Agents settings); you review it, then confirm to push and open it.",
        models: [.balanced, .fast, .strong], enabledByDefault: true,
        templates: [
            AITemplate(id: "title", title: "PR title", defaultText: "[{{issue_key}}] {{issue_title}}",
                       variables: pullRequestVariables),
            AITemplate(id: "body", title: "PR description", defaultText: "Jira: [{{issue_key}}]({{ticket_url}})\n\n{{summary}}",
                       variables: pullRequestVariables, multiline: true),
        ])

    static let pullRequestVariables = [
        "issue_key": "Jira key, e.g. PROJ-123", "issue_title": "Ticket summary", "ticket_url": "Link to the ticket",
        "summary": "The agent's final message", "branch": "Agent branch", "base": "Target branch",
    ]

    var aiTasks: [AITask] { [Self.agentTask, Self.pullRequestTask] }
    var ai: AISettings { host?.aiSettings(.extension(id), tasks: aiTasks) ?? AISettings(tasks: aiTasks) }

    /// Splits "Bash(git log:*) Bash(go test:*)" on whitespace outside parentheses, so rules
    /// with spaces in their pattern stay whole.
    static func toolRules(_ text: String) -> [String] {
        var rules: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character.isWhitespace && depth == 0 {
                if !current.isEmpty { rules.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { rules.append(current) }
        return rules
    }

    /// The process reports a running total; a lower total means it restarted and counts from zero.
    static func costDelta(total: Double, previous: Double) -> Double {
        total >= previous ? total - previous : total
    }

    // MARK: Lifecycle

    /// `<clone>/.worktrees/<branch, with / as ->`.
    static func worktreeURL(repo: URL, branch: String) -> URL {
        repo.appending(path: ".worktrees").appending(path: branch.replacingOccurrences(of: "/", with: "-"))
    }

    /// A local path (absolute or ~), or a repository ("owner/name", git URL) cloned into
    /// `<codeRoot>/<name>` when it isn't there yet. `.worktrees/` is kept out of git status.
    static func ensureClone(_ reference: String, codeRoot: String) async throws -> URL {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let url = URL(filePath: (trimmed as NSString).expandingTildeInPath)
            try excludeWorktrees(url)
            return url
        }
        let remote = trimmed.contains("://") || trimmed.hasPrefix("git@") ? trimmed : "git@github.com:\(trimmed).git"
        var name = String(remote.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty else { throw ToolError("Can't tell the repository name from \(reference).") }
        let root = URL(filePath: (codeRoot as NSString).expandingTildeInPath)
        let clone = root.appending(path: name)
        if !FileManager.default.fileExists(atPath: clone.appending(path: ".git").path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await Git.git(["clone", remote, clone.path], in: root)
        }
        try excludeWorktrees(clone)
        return clone
    }

    /// Adds `.worktrees/` to the clone's .git/info/exclude (local only, never committed).
    static func excludeWorktrees(_ clone: URL) throws {
        let exclude = clone.appending(path: ".git/info/exclude")
        guard FileManager.default.fileExists(atPath: clone.appending(path: ".git").path) else { return }
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".worktrees/" }) else { return }
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".worktrees/\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// Creates a worktree and branch for a Jira issue and starts the planning conversation.
    func start(issueKey: String, repoPath explicitRepo: String? = nil) async throws -> AgentSession {
        guard let host else { throw ToolError("Agents are not ready.") }
        let key = issueKey.uppercased()
        let project = String(key.split(separator: "-").first ?? "")
        guard let reference = explicitRepo ?? repoMap[project] else {
            throw ToolError("No repository for project \(project). Add \"\(project)=owner/name\" (or a local path) in Settings › Agents, or pass repo_path.")
        }
        let repoPath = try await Self.ensureClone(reference, codeRoot: codeRoot).path
        let jira = host.integration("atlassian")?.connection.map(JiraClient.init(connection:))
        let detail = try await jira?.issueDetail(key)
        let summary = detail?["summary"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? key

        let repo = URL(filePath: repoPath)
        let branch = Git.branchName(key: key, summary: summary)
        let worktree = Self.worktreeURL(repo: repo, branch: branch)
        _ = try? await Git.git(["fetch", "origin", "--prune"], in: repo)
        let base = await Git.remoteDefaultBranch(repo)
        if !FileManager.default.fileExists(atPath: worktree.path) {
            try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
            let branchExists = (try? await Git.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
            try await Git.git(branchExists ? ["worktree", "add", worktree.path, branch] : ["worktree", "add", "-b", branch, worktree.path, base], in: repo)
        }

        let session = AgentSession(issueKey: key, title: summary, repoPath: repoPath, worktreePath: worktree.path, branch: branch, baseRef: base)
        host.context.insert(session)
        try host.context.save()

        let ticket = Self.ticketText(detail: detail, key: key, summary: summary)
        send(session, message: Self.planPrompt(key: key, summary: summary, ticket: ticket, branch: branch, base: base),
             displayText: "Plan \(key) with extreme TDD.")
        return session
    }

    /// Switches to the implementation phase and tells the agent to start the TDD loop.
    func implement(_ session: AgentSession) {
        session.phase = "implementing"
        let process = processes[session.id]
        let mode = permissionMode
        Task {
            try? await process?.setPermissionMode(mode)
            send(session, message: Self.implementPrompt, displayText: "Implement the plan.")
        }
    }

    func send(_ session: AgentSession, message: String, displayText: String? = nil) {
        guard !running.contains(session.id) else { return }
        append(session, role: "user", text: displayText ?? message)
        do {
            let process = try processes[session.id] ?? launch(session)
            running.insert(session.id)
            session.status = "running"
            session.lastError = nil
            try process.send(message)
        } catch {
            running.remove(session.id)
            fail(session, error)
        }
    }

    /// Interrupts the current turn; the process stays up for the next message.
    func cancel(_ session: AgentSession) {
        let process = processes[session.id]
        Task { try? await process?.interrupt() }
    }

    /// Shell commands an agent may never run: pushing, and the tools that can write to a forge.
    static let remoteWriteRules = [
        "Bash(git push:*)", "Bash(git send-email:*)",
        "Bash(gh:*)", "Bash(glab:*)", "Bash(tea:*)", "Bash(hub:*)",
        "Bash(curl:*)", "Bash(wget:*)", "Bash(http:*)", "Bash(https:*)", "Bash(xh:*)",
    ]

    /// The Claude Code options for a session's process.
    func options(for session: AgentSession) -> ClaudeCodeOptions {
        var options = ClaudeCodeOptions()
        options.executable = claudeExecutable
        options.cwd = URL(filePath: session.worktreePath)
        options.permissionMode = session.phase == "planning" ? .plan : permissionMode
        options.allowedTools = Self.toolRules(allowedToolsText)
        // Nothing leaves this Mac from an agent: no pushes, and no comments, reviews or other
        // writes on GitHub or GitLab (their CLIs and raw HTTP clients are blocked outright).
        options.disallowedTools = Self.remoteWriteRules
        // The user is the sole author of the agent's commits: Claude Code adds no co-author trailer.
        options.settings = #"{"includeCoAuthoredBy": false}"#
        options.systemPrompt = .append(Self.tddPrompt)
        options.resume = session.claudeSessionID
        // The older free-text model setting wins when set; otherwise the AI tab's choice.
        options.model = model.isEmpty ? ai.model(Self.agentTask.id).rawValue : model
        if let effort = ai.effort(Self.agentTask.id) { options.effort = effort.rawValue }
        // Use the Claude Code login rather than an API key the app may have inherited.
        options.removedEnvironment = ["ANTHROPIC_API_KEY"]
        return options
    }

    private func launch(_ session: AgentSession) throws -> ClaudeCodeSession {
        var options = options(for: session)
        let issue = session.issueKey
        options.canUseTool = { [weak self] request in
            await self?.approve(request, issue: issue) ?? .deny(message: "Dash is closing.")
        }
        let process = try ClaudeCodeSession(options: options)
        processes[session.id] = process
        reportedCost[session.id] = 0
        Task { await consume(process, sessionID: session.id) }
        return process
    }

    /// Tool calls outside the pre-approved list come here; the user answers in a modal.
    private func approve(_ request: ToolPermissionRequest, issue: String) async -> PermissionDecision {
        let allowed = await host?.permissions.ask(
            icon: "hammer", title: "Agent on \(issue) wants to use \(request.toolName)",
            message: "This tool call is not in the pre-approved list in Settings › Agents.",
            details: [.init(title: request.toolName, text: Self.describe(request.input))],
            allowLabel: "Allow Once") ?? false
        return allowed ? .allow() : .deny(message: "The user declined this tool call. Ask them how to proceed.")
    }

    private func consume(_ process: ClaudeCodeSession, sessionID: UUID) async {
        do {
            for try await message in process.messages {
                guard let session = session(sessionID) else { continue }
                handle(message, session: session)
            }
        } catch {
            if let session = session(sessionID) { fail(session, error) }
        }
        processes[sessionID] = nil
        running.remove(sessionID)
        if let session = session(sessionID), session.status == "running" { session.status = "idle" }
        try? host?.context.save()
    }

    /// Records one CLI message in the transcript and updates the session's state.
    func handle(_ message: Message, session: AgentSession) {
        if let id = message.sessionID, session.claudeSessionID != id { session.claudeSessionID = id }
        switch message {
        case .assistant(let reply):
            for block in reply.content {
                switch block {
                case .text(let text) where !text.isEmpty: append(session, role: "assistant", text: text)
                case .toolUse(_, let name, let input): append(session, role: "tool", text: Self.describeTool(name: name, input: input))
                default: break
                }
            }
        case .result(let result):
            session.costUSD += Self.costDelta(total: result.totalCostUSD, previous: reportedCost[session.id] ?? 0)
            reportedCost[session.id] = result.totalCostUSD
            if result.isError {
                append(session, role: result.subtype == "error_during_execution" ? "info" : "error",
                       text: result.subtype == "error_during_execution" ? "Stopped." : (result.result ?? result.subtype))
            }
            running.remove(session.id)
            session.status = "idle"
            host?.emit(result.isError ? "agent.stopped" : "agent.turn_finished", from: self,
                       title: "Agent on \(session.issueKey) \(result.isError ? "stopped" : "finished its turn") (\(session.phase))",
                       detail: result.result.map { String($0.prefix(200)) }, importance: result.isError ? .notable : .info)
        default:
            break
        }
        session.updatedAt = .now
    }

    static func describeTool(name: String, input: ClaudeCodeKit.JSON) -> String {
        let detail = input["command"]?.string ?? input["file_path"]?.string ?? input["pattern"]?.string ?? input["description"]?.string ?? ""
        return detail.isEmpty ? name : "\(name): \(detail)"
    }

    static func describe(_ input: ClaudeCodeKit.JSON) -> String {
        input["command"]?.string ?? input["file_path"]?.string ?? input.line
    }

    func append(_ session: AgentSession, role: String, text: String) {
        guard let host else { return }
        host.context.insert(AgentMessage(sessionID: session.id, sequence: session.nextSequence, role: role, text: text))
        session.nextSequence += 1
        session.updatedAt = .now
        try? host.context.save()
    }

    func fail(_ session: AgentSession, _ error: Error) {
        session.status = "failed"
        session.lastError = error.localizedDescription
        host?.emit("agent.failed", from: self, title: "Agent on \(session.issueKey) failed", detail: error.localizedDescription, importance: .critical)
        append(session, role: "error", text: error.localizedDescription)
    }

    func messages(_ sessionID: UUID) -> [AgentMessage] {
        let descriptor = FetchDescriptor<AgentMessage>(predicate: #Predicate { $0.sessionID == sessionID }, sortBy: [SortDescriptor(\.sequence)])
        return (try? host?.context.fetch(descriptor)) ?? []
    }

    /// The ticket's browse URL on the connected Jira site.
    func ticketURL(_ issueKey: String) -> URL? {
        host?.integration("atlassian")?.connection.map { JiraClient(connection: $0).browseURL(issueKey) }
    }

    /// The repository's own PR template, if the user set one; otherwise the global one applies.
    func pullRequestTemplate(for repoPath: String) -> PullRequestTemplate? {
        try? host?.context.fetch(FetchDescriptor<PullRequestTemplate>(predicate: #Predicate { $0.repoPath == repoPath })).first
    }

    /// Renders the PR title and description for review. Nothing leaves the Mac until the user
    /// confirms with `createPullRequest(_:draft:)`.
    func draftPullRequest(_ session: AgentSession) async throws -> PullRequestDraft {
        guard ai.isEnabled(Self.pullRequestTask.id) else {
            throw ToolError("Opening PRs is turned off in Agents › AI settings.")
        }
        guard host?.integration("github")?.connection != nil else { throw ToolError("Connect GitHub to open pull requests.") }
        let worktree = URL(filePath: session.worktreePath)
        let ahead = try await Git.git(["rev-list", "--count", "\(session.baseRef)..HEAD"], in: worktree)
        guard Int(ahead) ?? 0 > 0 else { throw ToolError("The branch has no commits yet.") }
        let summary = messages(session.id).last { $0.role == "assistant" }?.text ?? ""
        let base = session.baseRef.replacingOccurrences(of: "origin/", with: "")
        let values = [
            "issue_key": session.issueKey, "issue_title": session.title, "ticket_url": ticketURL(session.issueKey)?.absoluteString ?? "",
            "summary": summary, "branch": session.branch, "base": base,
        ]
        let task = Self.pullRequestTask.id
        let template = pullRequestTemplate(for: session.repoPath)
        return PullRequestDraft(
            title: template.map { AISettings.render($0.title, values) } ?? ai.render(task, "title", values),
            body: template.map { AISettings.render($0.body, values) } ?? ai.render(task, "body", values),
            base: base, branch: session.branch, repoTemplate: template != nil)
    }

    /// Answers a question about the drafted PR (why a sentence is there, what a change does)
    /// from the branch's commits, diff summary and the agent's last report. Read-only.
    func explain(_ draft: PullRequestDraft, question: String, session: AgentSession) async throws -> String {
        guard let claude = host?.dashii else { throw ToolError("Agents are not ready.") }
        let worktree = URL(filePath: session.worktreePath)
        let log = (try? await Git.git(["log", "--oneline", "\(session.baseRef)..HEAD"], in: worktree)) ?? ""
        let stat = (try? await Git.git(["diff", "--stat", "\(session.baseRef)...HEAD"], in: worktree)) ?? ""
        let report = messages(session.id).last { $0.role == "assistant" }?.text ?? ""
        return try await claude.complete(task: Self.pullRequestTask.id, settings: ai, system: """
            You help the user review a pull request before they open it. Answer their question about the \
            title or description briefly and concretely, citing the commits or files involved. If the \
            description says something the changes do not support, say so and suggest a correction.
            """, prompt: """
            <title>\(draft.title)</title>
            <description>\(draft.body)</description>
            <commits>\(log)</commits>
            <diffstat>\(stat)</diffstat>
            <agent-report>\(report)</agent-report>

            \(question)
            """)
    }

    /// Pushes the branch and opens the draft PR the user reviewed and confirmed.
    func createPullRequest(_ session: AgentSession, draft: PullRequestDraft) async throws -> String {
        guard let connection = host?.integration("github")?.connection else { throw ToolError("Connect GitHub to open pull requests.") }
        let github = GitHubClient(connection: connection)
        let worktree = URL(filePath: session.worktreePath)
        let slug = try await Git.gitHubSlug(worktree)
        try await Git.git(["push", "-u", "origin", session.branch], in: worktree)
        let pull = try await github.createPull(slug, title: draft.title, head: session.branch, base: draft.base, body: draft.body, draft: true)
        let url = pull["html_url"]?.string ?? ""
        session.prURL = url
        append(session, role: "info", text: "Opened draft PR \(url)")
        // The Pull Requests feature picks the new PR up on its next poll.
        host?.emit("agent.pr_opened", from: self, title: "Draft PR opened for \(session.issueKey)", link: url, importance: .notable)
        return url
    }
}
