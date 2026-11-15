import DashKit
import DashKitUI
import SwiftUI
import WorkspaceKit

/// The Workspaces pane in Settings: environment, region, profiles, merge cleanup and clean.
struct WorkspacesSettings: View {
    @Bindable var feature: WorkspacesFeature
    @State private var candidates: [(workspace: Workspace, reason: String)] = []
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Environment", selection: $feature.env) {
                    ForEach(WorkspaceEnvironment.allCases, id: \.self) { Text("\($0.rawValue) (\($0.project))").tag($0) }
                }
                Picker("Region", selection: $feature.region) {
                    ForEach(WorkspaceRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Your deployed_by name", text: $feature.username)
                Stepper("Refresh every \(feature.pollMinutes) min", value: $feature.pollMinutes, in: 1...30)
            } header: {
                Text("Uses the Google Cloud integration")
            } footer: {
                Text(feature.lastError ?? "Talks to the GKE and Kubernetes APIs directly; kubectl and up-toolbox aren't used.")
                    .foregroundStyle(feature.lastError == nil ? Color.secondary : .red)
            }
            Section("Profiles") {
                ProfilesEditor(feature: feature)
            }
            Section("When a PR is merged") {
                Toggle("Delete my workspace deployed from its branch (unless persisted)", isOn: $feature.removeWhenMerged)
            }
            Section("Clean") {
                ForEach(candidates, id: \.workspace.name) { item in
                    LabeledContent(item.workspace.name, value: item.reason)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("Find Stale Workspaces") {
                        Task {
                            do { candidates = try await feature.client().cleanCandidates(); message = candidates.isEmpty ? "Nothing to clean." : nil } catch { message = WorkspacesFeature.describe(error) }
                        }
                    }
                    Spacer()
                    Button("Delete \(candidates.count)…", role: .destructive) {
                        Task {
                            let names = candidates.map(\.workspace.name)
                            for name in names { try? await feature.delete(name) }
                            candidates = []
                        }
                    }
                    .disabled(candidates.isEmpty)
                }
            }
        }
    }
}
