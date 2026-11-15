import AppKit
import DashKit
import DashKitUI
import SwiftUI
import WorkspaceKit

/// One workspace: status, tabs for its train, logs, diagnosis, config and commands, and actions.
struct WorkspaceSheet: View {
    let name: String
    let feature: WorkspacesFeature
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @State private var status: WorkspaceStatus?
    @State private var error: String?
    @State private var working = false
    @State private var tab = WorkspaceTab.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name).font(.title3.bold().monospaced())
                if let workspace = status?.workspace { NodePoolBadge(pool: workspace.nodePool) }
                Spacer()
                if let url = status.flatMap({ URL(string: "https://\($0.workspace.url)") }) { Link("Open", destination: url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("View", selection: $tab) { ForEach(WorkspaceTab.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch tab {
            case .train: WorkspaceTrainView(name: name, feature: feature)
            case .logs: WorkspaceLogsView(name: name, feature: feature)
            case .cloud: WorkspaceCloudLogsView(name: name, feature: feature)
            case .diagnose: WorkspaceDiagnoseView(name: name, feature: feature)
            case .config: WorkspaceConfigView(name: name, feature: feature)
            case .commands: WorkspaceCommandsView(name: name, feature: feature)
            case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let status {
                        Text("Deployed by \(status.workspace.deployedBy)\(status.workspace.gitBranch.map { " from \($0)" } ?? "")")
                            .foregroundStyle(.secondary)
                        Text("Deployments").font(.headline)
                        ForEach(status.deployments, id: \.name) { deployment in
                            HStack {
                                Image(systemName: deployment.ready >= deployment.desired ? "checkmark.circle.fill" : "hourglass")
                                    .foregroundStyle(deployment.ready >= deployment.desired ? .green : .orange)
                                Text(deployment.name).font(.callout.monospaced())
                                Text("\(deployment.ready)/\(deployment.desired)").foregroundStyle(.secondary)
                                Spacer()
                                Text(deployment.images.first?.split(separator: ":").last.map(String.init) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        let problems = status.pods.filter { $0.problem != nil || !$0.ready }
                        if !problems.isEmpty {
                            Text("Pods needing attention").font(.headline)
                            ForEach(problems, id: \.name) { pod in
                                Label("\(pod.name): \(pod.problem ?? pod.phase) · \(pod.restarts) restarts", systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.red)
                            }
                        }
                        if !status.hostnames.isEmpty {
                            Text("Hostnames").font(.headline)
                            ForEach(status.hostnames, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                        }
                    } else if error == nil {
                        ProgressView()
                    }
                    linkSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if let workspace = status?.workspace {
                    Button(workspace.persist ? "Stop Persisting" : "Persist") { run { try await feature.setPersist(name, !workspace.persist) } }
                }
                if feature.links[name] != nil {
                    Button("Deploy Worktree", systemImage: "arrow.up.circle") { run { try await feature.deployWorktree(name) } }
                        .help("Build the linked worktree and deploy it (up-toolbox workspace run)")
                }
                Button("Ask Dashii", systemImage: "sparkles") {
                    host.askDashii("Check workspace \(name): read its status and tell me if anything is wrong.")
                    dismiss()
                }
                Spacer()
                Button("Delete…", role: .destructive) { run { try await feature.delete(name); dismiss() } }
            }
            .disabled(working)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .task { await load() }
    }

    private func load() async {
        do { status = try await feature.client().status(name) } catch { self.error = WorkspacesFeature.describe(error) }
    }

    /// The worktree this workspace deploys from.
    @ViewBuilder private var linkSection: some View {
        Text("Code").font(.headline)
        if let link = feature.links[name] {
            Label((link.worktree as NSString).abbreviatingWithTildeInPath, systemImage: "arrow.triangle.branch").font(.callout.monospaced())
            if link.service != link.worktree { Text("builds \(URL(fileURLWithPath: link.service).lastPathComponent)").font(.caption).foregroundStyle(.secondary) }
        } else {
            Text("Not linked to a worktree.").foregroundStyle(.secondary)
        }
        Button(feature.links[name] == nil ? "Link a Worktree…" : "Change Worktree…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = URL(fileURLWithPath: (("~/Codes") as NSString).expandingTildeInPath)
            if panel.runModal() == .OK, let url = panel.url { feature.link(name, worktree: url.path) }
        }
        if working { ProgressView("Working… see Commands for each step").controlSize(.small) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await action(); await load() } catch { self.error = WorkspacesFeature.describe(error) }
            working = false
        }
    }
}
