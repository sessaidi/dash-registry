import DashKit
import DashKitUI
import SwiftUI

struct StatusPill: View {
    let name: String
    let category: String

    var body: some View {
        Badge(name, tone: category == "done" ? .success : category == "indeterminate" ? .info : .neutral)
    }
}

struct JiraIssueSheet: View {
    let issue: JiraTicket
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @State private var detail: JSONValue?
    @State private var transitions: [(id: String, name: String)] = []
    @State private var comment = ""
    @State private var error: String?
    @State private var busy = false

    private var jira: JiraBoardFeature? { host.ext(JiraBoardFeature.self) }

    /// The Agents feature's tools, reached by id so this plugin doesn't link another plugin.
    private func agentsTool(_ name: String) -> DashiiTool? {
        host.extensions.first { $0.id == "agents" && host.isEnabled($0) }?.tools.first { $0.name == name }
    }

    private var startAgent: DashiiTool? { agentsTool("agents_start") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(issue.key).font(.headline.monospaced())
                StatusPill(name: issue.statusName, category: issue.statusCategory)
                Spacer()
                if let url = URL(string: issue.url) { Link("Open in Jira", destination: url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(issue.summary).font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail {
                        Text(detail["description"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "No description.")
                            .textSelection(.enabled)
                        if let comments = detail["comments"]?.array, !comments.isEmpty {
                            Divider()
                            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(comment["author"]?.string ?? "").font(.caption.bold())
                                    Text(comment["body"]?.string ?? "").font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                TextField("Comment", text: $comment)
                Button("Post") { run { try await jira?.client.comment(issue.key, text: comment); comment = "" } }
                    .disabled(comment.isEmpty || busy)
            }
            HStack {
                Menu("Move to") {
                    ForEach(transitions, id: \.id) { transition in
                        Button(transition.name) { run { _ = try await jira?.move(issue.key, toStatus: transition.name) } }
                    }
                }
                .fixedSize()
                .disabled(transitions.isEmpty || busy)
                Button("Ask Dashii", systemImage: "sparkles") {
                    host.askDashii("Look at Jira issue \(issue.key) and suggest how to approach it.")
                    dismiss()
                }
                Spacer()
                Button("Start Agent", systemImage: "hammer") {
                    run {
                        guard let startAgent else { return }
                        let session = try await startAgent.run(["issue_key": .string(issue.key)])
                        dismiss()
                        // The Agents plugin owns its chat windows; ask it to open this one.
                        if let id = session["id"]?.string {
                            _ = try? await agentsTool("agents_open")?.run(["session_id": .string(id)])
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || startAgent == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task {
            guard let client = try? jira?.client else { return }
            detail = try? await client.issueDetail(issue.key)
            transitions = (try? await client.transitions(issue.key)) ?? []
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
