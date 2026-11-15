import DashKit
import Foundation
import SwiftData

/// Dashii tools: start, list, message and read agent sessions, open their windows.
extension AgentsExtension {
    private struct StartInput: Decodable { let issue_key: String; let repo_path: String? }
    private struct SendInput: Decodable { let session_id: String; let message: String }
    private struct SessionInput: Decodable { let session_id: String; let last: Int? }

    func session(from text: String) throws -> AgentSession {
        guard let id = UUID(uuidString: text), let session = session(id) else { throw ToolError("No agent session \(text). Call agents_list.") }
        return session
    }

    private struct OpenInput: Decodable { let session_id: String }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "agents_list", description: "List coding-agent sessions with their ticket, branch, phase (planning or implementing), status and cost.") { [weak self] _ in
                guard let self, let host else { return [] }
                let sessions = (try? host.context.fetch(FetchDescriptor<AgentSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
                return .array(sessions.map(\.json))
            },
            DashiiTool(
                name: "agents_start",
                description: "Start a Dashii agent on a Jira ticket: creates a git worktree and branch, then the agent proposes a TDD plan.",
                properties: [
                    "issue_key": JSONSchema.string("Jira issue key."),
                    "repo_path": JSONSchema.string("Local repository path; defaults to the project's mapping in settings."),
                ],
                required: ["issue_key"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(StartInput.self)
                return try await start(issueKey: request.issue_key, repoPath: request.repo_path).json
            },
            DashiiTool(
                name: "agents_open",
                description: "Open an agent session's chat window so the user can follow and talk to the agent.",
                properties: ["session_id": JSONSchema.string("Session id.")],
                required: ["session_id"]
            ) { [weak self] input in
                guard let self else { return nil }
                let session = try session(from: try input.toolInput(OpenInput.self).session_id)
                openWindow(session.id)
                return .string("opened")
            },
            DashiiTool(
                name: "agents_send",
                description: "Send a message to an agent session (it must be idle). The agent answers in its own window; read the reply with agents_read.",
                properties: ["session_id": JSONSchema.string("Session id."), "message": JSONSchema.string("Message to the agent.")],
                required: ["session_id", "message"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(SendInput.self)
                let session = try session(from: request.session_id)
                guard !isRunning(session.id) else { throw ToolError("The agent is busy. Try again when it is idle.") }
                send(session, message: request.message)
                return "sent"
            },
            DashiiTool(
                name: "agents_read",
                description: "Read an agent session's recent transcript.",
                properties: ["session_id": JSONSchema.string("Session id."), "last": JSONSchema.integer("Number of recent messages (default 30).")],
                required: ["session_id"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(SessionInput.self)
                let session = try session(from: request.session_id)
                return session.json.merging(["messages": .array(messages(session.id).suffix(request.last ?? 30).map {
                    ["role": .string($0.role), "text": .string($0.text)]
                })])
            },
        ]
    }
}
