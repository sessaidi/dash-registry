import ClaudeCodeKit
import DashKit
import DashKitUI
import Foundation
import SwiftData
import Testing

@MainActor
@Suite(.serialized)
struct AgentsExtensionTests {
    // MARK: Identity (ported from Dash's CoreTests.featuresDeclareTheirIntegrations)

    @Test func identityAndContracts() {
        let (agents, _) = makeAgents()
        #expect(agents.id == "agents" && agents.name == "Agents" && agents.systemImage == "hammer")
        #expect(agents.layer == .feature)
        #expect(agents.requires == ["atlassian"] && agents.optional == ["github"])
        #expect(agents.metadata.version == "1.10.0" && agents.metadata.category == .ai)
        #expect(agents.storagePrefix == "agents")
        #expect(agents.models.map { String(describing: $0) } == ["AgentSession", "AgentMessage", "PullRequestTemplate"])
        #expect(agents.widgets.map(\.kind) == ["agents.sessions", "agents.worktrees"])
        #expect(agents.tools.map(\.name) == ["agents_list", "agents_start", "agents_open", "agents_send", "agents_read",
                                             "worktrees_list", "worktrees_for_branch", "worktree_link"])
        #expect(agents.tools.filter(\.requiresApproval).map(\.name) == ["agents_start", "agents_send"])
    }

    @Test func pluginEntryMakesTheExtension() {
        #expect(AgentsPlugin.makeExtensions().map(\.id) == ["agents"])
    }

    // MARK: Preferences

    @Test func defaultsWhenNothingIsStored() {
        let (agents, _) = makeAgents()
        #expect(agents.claudePath == "" && agents.model == "" && agents.repoMapText == "")
        #expect(agents.implementPermissionMode == "acceptEdits")
        #expect(agents.allowedToolsText == AgentsExtension.defaultAllowedTools)
        #expect(agents.codeRoot == "~/Codes")
    }

    @Test func readsAndWritesTheSamePreferenceKeys() {
        var store: UserDefaults?
        let (agents, _) = makeAgents { defaults in
            store = defaults
            defaults.set("/usr/local/bin/claude", forKey: "agents.claudePath")
            defaults.set("/tmp/wt", forKey: "agents.codeRoot")
            defaults.set("KAN=/code/kan", forKey: "agents.repoMap")
            defaults.set("bypassPermissions", forKey: "agents.permissionMode")
            defaults.set("Bash(make:*)", forKey: "agents.allowedTools")
            defaults.set("claude-opus-5-5", forKey: "agents.model")
        }
        #expect(agents.claudePath == "/usr/local/bin/claude" && agents.codeRoot == "/tmp/wt")
        #expect(agents.repoMapText == "KAN=/code/kan" && agents.implementPermissionMode == "bypassPermissions")
        #expect(agents.allowedToolsText == "Bash(make:*)" && agents.model == "claude-opus-5-5")

        agents.model = "claude-sonnet-5"
        agents.repoMapText = "OPS=/code/ops"
        agents.claudePath = ""
        agents.codeRoot = "/tmp/other"
        agents.implementPermissionMode = "acceptEdits"
        agents.allowedToolsText = "Bash(go test:*)"
        let defaults = try! #require(store)
        #expect(defaults.string(forKey: "agents.model") == "claude-sonnet-5")
        #expect(defaults.string(forKey: "agents.repoMap") == "OPS=/code/ops")
        #expect(defaults.string(forKey: "agents.claudePath") == "")
        #expect(defaults.string(forKey: "agents.codeRoot") == "/tmp/other")
        #expect(defaults.string(forKey: "agents.permissionMode") == "acceptEdits")
        #expect(defaults.string(forKey: "agents.allowedTools") == "Bash(go test:*)")
    }

    @Test func repoMapParsesProjectLines() {
        let (agents, _) = makeAgents()
        agents.repoMapText = """
            kan = ~/code/api
            OPS=/srv/ops
            broken line
            =/nowhere
            EMPTY=
            OPS=/srv/ops-v2
            """
        // Paths stay as written (expanded, or cloned for owner/name, when an agent starts).
        #expect(agents.repoMap == ["KAN": "~/code/api", "OPS": "/srv/ops-v2"])
    }

    @Test func claudeExecutablePrefersOwnPathThenDashsSetting() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AgentsExtension.executable(own: "~/bin/claude", app: "/opt/homebrew/bin/claude")?.path == "\(home)/bin/claude")
        #expect(AgentsExtension.executable(own: "", app: "/opt/homebrew/bin/claude")?.path == "/opt/homebrew/bin/claude")
        #expect(AgentsExtension.executable(own: "", app: nil) == nil)
        #expect(AgentsExtension.executable(own: "", app: "") == nil)

        let (agents, _) = makeAgents { $0.set("/usr/local/bin/claude", forKey: "claudePath") }
        #expect(agents.claudeExecutable?.path == "/usr/local/bin/claude")
    }

    // MARK: Claude Code options

    @Test func planningRunsInPlanModeAndImplementingUsesTheSetting() {
        let (agents, _) = makeAgents()
        agents.allowedToolsText = "Bash(make:*) Bash(go test:*)"
        let session = AgentSession(issueKey: "KAN-1", title: "t", repoPath: "/r", worktreePath: "/w/kan-1", branch: "kan-1", baseRef: "origin/main")
        session.claudeSessionID = "abc"
        var options = agents.options(for: session)
        #expect(options.permissionMode == .plan)
        #expect(options.cwd?.path == "/w/kan-1")
        #expect(options.allowedTools == ["Bash(make:*)", "Bash(go test:*)"])
        // Agents can't write remotely: no push, no forge CLIs, no raw HTTP clients.
        #expect(options.disallowedTools == AgentsExtension.remoteWriteRules)
        for rule in ["Bash(git push:*)", "Bash(gh:*)", "Bash(glab:*)", "Bash(curl:*)"] { #expect(options.disallowedTools.contains(rule)) }
        #expect(AgentsExtension.tddPrompt.contains("Never write anything remotely"))
        #expect(options.systemPrompt == .append(AgentsExtension.tddPrompt))
        // No free-text model: the AI tab's choice (Opus by default, high effort).
        #expect(options.resume == "abc" && options.model == DashiiModel.strong.rawValue && options.effort == "high")
        #expect(options.removedEnvironment == ["ANTHROPIC_API_KEY"])

        session.phase = "implementing"
        agents.model = "claude-opus-5-5"
        options = agents.options(for: session)
        #expect(options.permissionMode == .acceptEdits && options.model == "claude-opus-5-5")
        agents.implementPermissionMode = "bypassPermissions"
        #expect(agents.options(for: session).permissionMode == .bypassPermissions)
        agents.implementPermissionMode = "nonsense"
        #expect(agents.options(for: session).permissionMode == .acceptEdits)
    }

    // MARK: Prompts and PR text

    @Test func planPromptCarriesTicketBranchAndBase() {
        let prompt = AgentsExtension.planPrompt(key: "KAN-9", summary: "Add retry", ticket: "{\"key\": \"KAN-9\"}", branch: "kan-9-add-retry", base: "origin/main")
        #expect(prompt.hasPrefix("You are working on Jira ticket KAN-9: Add retry\n\n<ticket>\n{\"key\": \"KAN-9\"}\n</ticket>"))
        #expect(prompt.contains("on branch kan-9-add-retry, created from origin/main. Read the relevant code, then propose"))
        #expect(prompt.hasSuffix("Don't edit files yet; we'll agree the plan first."))
        #expect(AgentsExtension.implementPrompt.contains("extreme TDD loop"))
        #expect(AgentsExtension.tddPrompt.contains("Do not push, open pull requests"))
    }

    @Test func ticketTextFallsBackToKeyAndSummary() throws {
        #expect(AgentsExtension.ticketText(detail: nil, key: "X-1", summary: "Do it") == "{\"key\": \"X-1\", \"summary\": \"Do it\"}")
        let detail: JSONValue = ["key": "X-1", "summary": "Do it"]
        #expect(try JSONValue.parse(AgentsExtension.ticketText(detail: detail, key: "X-1", summary: "ignored")) == detail)
    }

    @Test func pullRequestTitleAndBody() {
        #expect(AgentsExtension.pullRequestTitle(issueKey: "KAN-3", title: "Add retry") == "[KAN-3] Add retry")
        let url = URL(string: "https://acme.atlassian.net/browse/KAN-3")!
        #expect(AgentsExtension.pullRequestBody(issueKey: "KAN-3", ticketURL: url, summary: "Done.")
            == "Jira: [KAN-3](https://acme.atlassian.net/browse/KAN-3)\n\nDone.")
        #expect(AgentsExtension.pullRequestBody(issueKey: "KAN-3", ticketURL: nil, summary: "") == "Jira: KAN-3\n\n")
    }

    @Test func ticketURLComesFromTheAtlassianConnection() {
        let (agents, _) = makeAgents([FakeIntegration(id: "atlassian", baseURL: URL(string: "https://acme.atlassian.net")!)])
        #expect(agents.ticketURL("KAN-3")?.absoluteString == "https://acme.atlassian.net/browse/KAN-3")
        #expect(makeAgents().0.ticketURL("KAN-3") == nil)
    }

    @Test func toolRulesKeepSpacesInsideParentheses() {
        #expect(AgentsExtension.toolRules("Bash(git log:*)  Bash(go test:*)\nRead WebFetch(domain:x.com)")
            == ["Bash(git log:*)", "Bash(go test:*)", "Read", "WebFetch(domain:x.com)"])
        #expect(AgentsExtension.toolRules("") == [])
        #expect(AgentsExtension.toolRules(AgentsExtension.defaultAllowedTools).count == 18)
        #expect(AgentsExtension.toolRules(AgentsExtension.defaultAllowedTools).contains("Bash(go test:*)"))
    }

    @Test func costDeltaHandlesRestartedProcesses() {
        #expect(AgentsExtension.costDelta(total: 0.75, previous: 0.5) == 0.25)
        #expect(AgentsExtension.costDelta(total: 0.2, previous: 0.5) == 0.2)
        #expect(AgentsExtension.costDelta(total: 0, previous: 0) == 0)
    }

    @Test func describesToolCalls() throws {
        #expect(AgentsExtension.describeTool(name: "Bash", input: ["command": "go test ./..."]) == "Bash: go test ./...")
        #expect(AgentsExtension.describeTool(name: "Edit", input: ["file_path": "/w/a.go"]) == "Edit: /w/a.go")
        #expect(AgentsExtension.describeTool(name: "Grep", input: ["pattern": "TODO"]) == "Grep: TODO")
        #expect(AgentsExtension.describeTool(name: "Task", input: ["description": "explore"]) == "Task: explore")
        #expect(AgentsExtension.describeTool(name: "TodoWrite", input: ["todos": []]) == "TodoWrite")
        #expect(AgentsExtension.describe(["command": "rm -rf build"]) == "rm -rf build")
        #expect(AgentsExtension.describe(["url": "https://x"]).contains("url"))
    }

    // MARK: State

    @Test func startResetsSessionsLeftRunning() throws {
        let (agents, host) = makeAgents()
        let stale = AgentSession(issueKey: "X-1", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        stale.status = "running"
        let failed = AgentSession(issueKey: "X-2", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        failed.status = "failed"
        host.context.insert(stale)
        host.context.insert(failed)
        try host.context.save()
        agents.start(host: host)
        #expect(stale.status == "idle" && failed.status == "failed")
        #expect(agents.session(stale.id) === stale)
        #expect(agents.session(UUID()) == nil)
    }

    @Test func storeCountsAndDeletesAgentModels() throws {
        // Port of Dash's FoundationTests.dataSummaryCountsAndDeletesAnExtensionsModels, on the plugin's own models.
        let (_, host) = makeAgents()
        host.context.insert(AgentSession(issueKey: "X-1", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main"))
        try host.context.save()
        #expect(try host.context.fetchCount(FetchDescriptor<AgentSession>()) == 1)
        try host.context.delete(model: AgentSession.self)
        try host.context.delete(model: AgentMessage.self)
        #expect(try host.context.fetchCount(FetchDescriptor<AgentSession>()) == 0)
    }

    @Test func transcriptFollowsCLIMessages() throws {
        let (agents, host) = makeAgents()
        let session = AgentSession(issueKey: "KAN-7", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        host.context.insert(session)
        agents.append(session, role: "user", text: "Plan KAN-7 with extreme TDD.")

        agents.handle(try cliMessage(#"{"type":"system","subtype":"init","session_id":"cli-1"}"#), session: session)
        #expect(session.claudeSessionID == "cli-1")
        agents.handle(try cliMessage(#"""
            {"type":"assistant","session_id":"cli-1","message":{"content":[
              {"type":"text","text":"Here is the plan."},
              {"type":"text","text":""},
              {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"go test ./..."}}]}}
            """#), session: session)
        agents.handle(try cliMessage(#"{"type":"result","subtype":"success","is_error":false,"result":"Planned.","session_id":"cli-1","total_cost_usd":0.5}"#), session: session)
        #expect(session.status == "idle" && session.costUSD == 0.5)
        agents.handle(try cliMessage(#"{"type":"result","subtype":"success","is_error":false,"result":"Again.","session_id":"cli-1","total_cost_usd":0.75}"#), session: session)
        #expect(session.costUSD == 0.75)
        agents.handle(try cliMessage(#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"cli-1","total_cost_usd":0.8}"#), session: session)
        agents.handle(try cliMessage(#"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"cli-1","total_cost_usd":0.9}"#), session: session)
        #expect(abs(session.costUSD - 0.9) < 0.0001)

        let transcript = agents.messages(session.id)
        #expect(transcript.map(\.role) == ["user", "assistant", "tool", "info", "error"])
        #expect(transcript.map(\.text) == ["Plan KAN-7 with extreme TDD.", "Here is the plan.", "Bash: go test ./...", "Stopped.", "error_max_turns"])
        #expect(transcript.map(\.sequence) == [0, 1, 2, 3, 4] && session.nextSequence == 5)

        let events = host.activity.events(after: 0)
        #expect(events.map(\.kind) == ["agent.turn_finished", "agent.turn_finished", "agent.stopped", "agent.stopped"])
        #expect(events.allSatisfy { $0.source == "agents" })
        #expect(events.first?.title == "Agent on KAN-7 finished its turn (planning)" && events.first?.detail == "Planned.")
    }

    @Test func failureMarksTheSessionAndAlerts() throws {
        let (agents, host) = makeAgents()
        let session = AgentSession(issueKey: "KAN-8", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        host.context.insert(session)
        agents.fail(session, ToolError("boom"))
        #expect(session.status == "failed" && session.lastError == "boom")
        #expect(agents.messages(session.id).map(\.role) == ["error"])
        let event = try #require(host.activity.events(after: 0).last)
        #expect(event.kind == "agent.failed" && event.importance == .critical)
    }

    @Test func sessionJSONKeepsItsShape() {
        let session = AgentSession(issueKey: "KAN-1", title: "Add retry", repoPath: "/r", worktreePath: "/w", branch: "kan-1-add-retry", baseRef: "origin/main")
        let json = session.json
        #expect(json["issue"] == "KAN-1" && json["title"] == "Add retry" && json["branch"] == "kan-1-add-retry")
        #expect(json["worktree"] == "/w" && json["phase"] == "planning" && json["status"] == "idle")
        #expect(json["cost_usd"] == 0 && json["pr_url"] == .null && json["error"] == .null)
        #expect(json["id"]?.string == session.id.uuidString)
    }

    // MARK: Tools

    @Test func listAndReadTools() async throws {
        let (agents, host) = makeAgents()
        let older = AgentSession(issueKey: "A-1", title: "old", repoPath: "/r", worktreePath: "/w", branch: "a-1", baseRef: "origin/main")
        older.updatedAt = .distantPast
        let newer = AgentSession(issueKey: "A-2", title: "new", repoPath: "/r", worktreePath: "/w", branch: "a-2", baseRef: "origin/main")
        host.context.insert(older)
        host.context.insert(newer)
        for index in 0..<5 { agents.append(newer, role: index.isMultiple(of: 2) ? "user" : "assistant", text: "m\(index)") }

        let list = try #require(agents.tools.first { $0.name == "agents_list" })
        #expect(try await list.run([:]).array?.compactMap { $0["issue"]?.string } == ["A-2", "A-1"])

        let read = try #require(agents.tools.first { $0.name == "agents_read" })
        let result = try await read.run(["session_id": .string(newer.id.uuidString), "last": 2])
        #expect(result["issue"] == "A-2")
        #expect(result["messages"]?.array?.compactMap { $0["text"]?.string } == ["m3", "m4"])
        #expect(try await read.run(["session_id": .string(newer.id.uuidString)])["messages"]?.array?.count == 5)

        await #expect(throws: ToolError.self) { try await read.run(["session_id": "not-a-uuid"]) }
        let send = try #require(agents.tools.first { $0.name == "agents_send" })
        await #expect(throws: ToolError.self) { try await send.run(["session_id": .string(UUID().uuidString), "message": "hi"]) }
    }

    @Test func startNeedsARepositoryMapping() async throws {
        let (agents, _) = makeAgents()
        let start = try #require(agents.tools.first { $0.name == "agents_start" })
        do {
            _ = try await start.run(["issue_key": "kan-12"])
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.message.contains("No repository for project KAN"))
        }
    }

    @Test func startNeedsAHost() async {
        let agents = AgentsExtension(defaults: UserDefaults(suiteName: "AgentsPluginTests.\(UUID().uuidString)")!)
        do {
            _ = try await agents.start(issueKey: "KAN-1", repoPath: "/tmp")
            Issue.record("expected an error")
        } catch {
            #expect(error as? ToolError == ToolError("Agents are not ready."))
        }
    }

    @Test func pullRequestNeedsGitHub() async {
        let (agents, _) = makeAgents()
        let session = AgentSession(issueKey: "KAN-1", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        do {
            _ = try await agents.draftPullRequest(session)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "Connect GitHub to open pull requests.")
        }
    }

    @Test func repositoryTemplateOverridesTheGlobalOne() throws {
        let (agents, host) = makeAgents()
        #expect(agents.pullRequestTemplate(for: "/r") == nil)
        host.context.insert(PullRequestTemplate(repoPath: "/r", title: "{{issue_key}}: {{issue_title}}", body: "Fixes {{issue_key}}"))
        try host.context.save()
        #expect(agents.pullRequestTemplate(for: "/r")?.title == "{{issue_key}}: {{issue_title}}")
        #expect(agents.pullRequestTemplate(for: "/other") == nil)
    }

    // MARK: Widget

    @Test func widgetContractAndSnapshot() async throws {
        #expect(AgentsWidget.kind == "agents.sessions")
        #expect(AgentsWidget.sizeLimits == GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20))
        #expect(AgentsWidget.defaultConfig == .init(showFinished: true))
        let type = WidgetType(AgentsWidget.self)
        #expect(type.preview != nil && type.sizeLimits == AgentsWidget.sizeLimits)
        _ = type.preview?(["showFinished": false])

        let (_, host) = makeAgents()
        let open = AgentSession(issueKey: "A-1", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        let done = AgentSession(issueKey: "A-2", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        done.prURL = "https://github.com/acme/api/pull/1"
        host.context.insert(open)
        host.context.insert(done)
        try host.context.save()
        let context = WidgetContext(widgetID: UUID(), host: host)
        #expect(await AgentsWidget.snapshot(config: .init(showFinished: true), context: context).array?.count == 2)
        #expect(await AgentsWidget.snapshot(config: .init(showFinished: false), context: context).array?.compactMap { $0["issue"]?.string } == ["A-1"])
    }

    @Test func sampleRowsCoverEveryStateWithoutTheStore() {
        let samples = AgentSummary.samples
        #expect(Set(samples.map(\.status)) == ["running", "idle", "failed"])
        #expect(Set(samples.map(\.phase)) == ["planning", "implementing"])
        #expect(AgentSummary.visible(samples, showFinished: true).count == samples.count)
        #expect(AgentSummary.visible(samples, showFinished: false).allSatisfy { !$0.hasPullRequest })
        #expect(AgentSummary.visible(samples, showFinished: false).count == samples.count - samples.count(where: \.hasPullRequest))

        let session = AgentSession(issueKey: "A-1", title: "t", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        session.prURL = "https://x"
        let row = AgentSummary(session)
        #expect(row.id == session.id && row.issueKey == "A-1" && row.hasPullRequest)
    }
}

@Suite
struct GitTests {
    @Test func branchNames() {
        #expect(Git.branchName(key: "KAN-1234", summary: "Add retry to the fetcher") == "kan-1234-add-retry-to-the-fetcher")
        #expect(Git.branchName(key: "OPS-1", summary: "  Fix: crash (when) *empty*!! ") == "ops-1-fix-crash-when-empty")
        #expect(Git.branchName(key: "X-1", summary: "") == "x-1")
        let long = Git.branchName(key: "KAN-1", summary: String(repeating: "word ", count: 30))
        #expect(long.count <= 50 && long.hasPrefix("kan-1-word-word"))
    }

    @Test func gitHubSlugsFromRemotes() throws {
        #expect(try Git.slug(fromRemote: "git@github.com:acme/api.git") == "acme/api")
        #expect(try Git.slug(fromRemote: "https://github.com/acme/api.git") == "acme/api")
        #expect(try Git.slug(fromRemote: "https://github.com/acme/api") == "acme/api")
        #expect(try Git.slug(fromRemote: "ssh://git@github.com/acme/api.git") == "acme/api")
        #expect(throws: ToolError.self) { try Git.slug(fromRemote: "https://gitlab.com/group/sub/api.git") }
    }

    @Test func defaultBranchFallsBackWithoutOrigin() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agents-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Git.git(["init", "--quiet"], in: repo)
        #expect(await Git.remoteDefaultBranch(repo) == "origin/main")
        await #expect(throws: ShellError.self) { try await Git.git(["remote", "get-url", "origin"], in: repo) }
    }

    @Test func shellReportsMissingExecutables() async {
        do {
            try await Shell.run("definitely-not-a-dash-command", [])
            Issue.record("expected an error")
        } catch let error as ShellError {
            #expect(error.status == -1 && error.output == "not found on PATH")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(Shell.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}

@MainActor
@Suite(.serialized)
struct ClientTests {
    @Test func jiraIssueDetailFlattensFieldsAndComments() async throws {
        StubProtocol.serve("jira-detail.test", json: """
            {"key":"KAN-5","fields":{"summary":"Add retry","status":{"name":"In Progress"},"issuetype":{"name":"Story"},
             "priority":{"name":"High"},"assignee":null,"reporter":{"displayName":"Ana"},"labels":["api"],"parent":{"key":"KAN-1"},
             "description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Retry "},{"type":"mention","attrs":{"text":"@Bo"}}]}]},
             "comment":{"comments":[{"author":{"displayName":"Bo"},"created":"2026-01-02T03:04:05.000+0000","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"ok"}]}]}}]}}}
            """)
        let jira = try #require(FakeIntegration(id: "atlassian", baseURL: URL(string: "https://jira-detail.test")!).connection.map(JiraClient.init(connection:)))
        let detail = try await jira.issueDetail("KAN-5")
        #expect(detail["summary"] == "Add retry" && detail["status"] == "In Progress" && detail["type"] == "Story")
        #expect(detail["assignee"] == "Unassigned" && detail["reporter"] == "Ana" && detail["parent"] == "KAN-1")
        #expect(detail["labels"] == ["api"] && detail["description"] == "Retry @Bo")
        #expect(detail["url"] == "https://jira-detail.test/browse/KAN-5")
        #expect(detail["comments"]?[0]?["author"] == "Bo" && detail["comments"]?[0]?["body"] == "ok")

        let request = try #require(StubProtocol.requests("jira-detail.test").first)
        #expect(request.url?.path() == "/rest/api/3/issue/KAN-5")
        #expect(request.url?.query()?.contains("description,comment") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake")
    }

    @Test func plainTextFromDocumentFormat() throws {
        let doc = try JSONValue.parse(#"""
            {"type":"doc","content":[
              {"type":"heading","content":[{"type":"text","text":"Goal"}]},
              {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"text","text":"one"}]}]},
              {"type":"paragraph","content":[{"type":"text","text":"a"},{"type":"hardBreak"},{"type":"text","text":"b"}]}]}
            """#)
        #expect(JiraClient.plainText(doc) == "Goal\n• one\na\nb")
        #expect(JiraClient.plainText("already text") == "already text")
        #expect(JiraClient.plainText(nil) == "")
    }

    @Test func gitHubCreatesADraftPull() async throws {
        StubProtocol.serve("github-pulls.test", json: #"{"html_url":"https://github.com/acme/api/pull/9"}"#, status: 201)
        let github = try #require(FakeIntegration(id: "github", baseURL: URL(string: "https://github-pulls.test")!).connection.map(GitHubClient.init(connection:)))
        let pull = try await github.createPull("acme/api", title: "[KAN-1] t", head: "kan-1-t", base: "main", body: "Jira: KAN-1", draft: true)
        #expect(pull["html_url"] == "https://github.com/acme/api/pull/9")

        let request = try #require(StubProtocol.requests("github-pulls.test").first)
        #expect(request.httpMethod == "POST" && request.url?.path() == "/repos/acme/api/pulls")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        // URLProtocol sees the body as a stream; the request was built with HTTP.request, which sets httpBody.
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let json = try JSONValue.parse(body)
        #expect(json["head"] == "kan-1-t" && json["base"] == "main" && json["draft"] == true && json["title"] == "[KAN-1] t")
    }

    static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The Agents widget's selection, for linked widgets.
@MainActor
struct AgentSelectionTests {
    @Test func selectsBySessionKeyOrIDAndPublishesItsRow() {
        let a = AgentSession(issueKey: "KAN-1", title: "One", repoPath: "/r", worktreePath: "/w", branch: "b", baseRef: "origin/main")
        let b = AgentSession(issueKey: "KAN-2", title: "Two", repoPath: "/r", worktreePath: "/w", branch: "c", baseRef: "origin/main")
        #expect(AgentSession.find("kan-2", in: [a, b])?.id == b.id)
        #expect(AgentSession.find(a.id.uuidString, in: [a, b])?.issueKey == "KAN-1")
        #expect(AgentSession.find("KAN-9", in: [a, b]) == nil)
        #expect(a.queryRow["issue_key"] == "KAN-1")
        #expect(AgentsWidget.actions.map(\.name) == ["select", "clear_selection"])
    }
}
