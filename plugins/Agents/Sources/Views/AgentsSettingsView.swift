import DashKit
import SwiftUI

/// The Agents settings.
struct AgentsSettingsView: View {
    @Bindable var agents: AgentsExtension

    var body: some View {
        Form {
            Section {
                TextField("claude CLI", text: $agents.claudePath, prompt: Text(agents.claudeExecutable?.path ?? Shell.which("claude")?.path ?? "/opt/homebrew/bin/claude"))
                TextField("Model", text: $agents.model, prompt: Text("Dashii default"))
            } footer: {
                Text("Agents run on Dashii's engine (Claude Code) with your login.")
            }
            Section {
                TextField("Code folder", text: $agents.codeRoot, prompt: Text("~/Codes"))
                Picker("Open files in", selection: Binding(
                    get: { Editor.preferred },
                    set: { DashStorage.defaults.set($0.rawValue, forKey: "agents.editor") })) {
                    ForEach(Editor.allCases) { editor in
                        Text(editor.name + (editor.isInstalled ? "" : " (not installed)")).tag(editor)
                    }
                }
                TextEditor(text: $agents.repoMapText)
                    .font(.body.monospaced())
                    .frame(height: 70)
            } header: {
                Text("Repositories")
            } footer: {
                Text("One per line: Jira project key = repository (owner/name, cloned into the code folder when missing) or a local path, e.g. KAN=acme/billing-api. Worktrees go in <clone>/.worktrees/<branch>.")
            }
            Section {
                Picker("While implementing", selection: $agents.implementPermissionMode) {
                    Text("Accept edits, pre-approved commands only").tag("acceptEdits")
                    Text("Bypass all permission checks").tag("bypassPermissions")
                }
                TextField("Pre-approved tools", text: $agents.allowedToolsText, axis: .vertical)
                    .font(.caption.monospaced())
                    .lineLimit(2...6)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Planning always runs in plan mode (read-only). The agent never writes remotely: git push, gh, glab and curl are blocked. Only Create PR pushes, after you review and confirm the title and description.")
            }
            WorktreesSettingsSection(store: agents.worktrees) { Task { await agents.refreshWorktrees() } }
            PullRequestTemplatesSection(agents: agents)
        }
    }
}
