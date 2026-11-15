import DashKit
import DashKitUI
import SwiftUI

/// The Docker pane in Settings/Extensions: the socket, detected runtimes and status.
struct DockerSettingsView: View {
    let integration: DockerIntegration
    @State private var socket = ""
    @State private var detected: [String] = []
    /// Which detected sockets Docker actually answers on (a socket file can outlive its runtime).
    @State private var alive: [String: Bool] = [:]

    var body: some View {
        Form {
            Section {
                ConnectionStatusLabel(integration.connectionState)
                LabeledContent("Socket") {
                    HStack {
                        TextField("Socket", text: $socket, prompt: Text(integration.socketPath ?? "Auto-detect"))
                            .labelsHidden()
                            .onSubmit(save)
                        Button("Save", action: save).disabled(socket == integration.socketPreference)
                    }
                }
                Text("Leave empty to use the first socket found.").font(.caption).foregroundStyle(.secondary)
                AsyncButton("Check Connection") { await integration.verify() }
            }
            Section("Detected sockets") {
                if detected.isEmpty {
                    Text("None found. Start Docker Desktop, Colima, OrbStack or Rancher Desktop.").foregroundStyle(.secondary)
                }
                ForEach(detected, id: \.self) { path in
                    ItemRow(path, monospacedTitle: true, leading: {
                        StatusDot(alive[path] == false ? .danger : alive[path] == true ? .success : .neutral)
                            .help(alive[path] == false ? "Not running: \(DockerSocket.startHint(path))" : alive[path] == true ? "Docker answers here" : "Checking…")
                    }, trailing: {
                        if alive[path] == false {
                            Text(path.contains("colima") ? "stopped · colima start" : "not running").font(.caption).foregroundStyle(.secondary)
                        }
                        if path != integration.socketPath {
                            Button("Use") {
                                socket = path
                                save()
                            }
                        }
                    })
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            socket = integration.socketPreference
            detected = DockerSocket.detected()
            Task {
                for path in detected { alive[path] = await UnixHTTP.answers(path) }
            }
        }
    }

    private func save() {
        integration.socketPreference = socket
        Task { await integration.verify() }
    }
}
