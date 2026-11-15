import DashKit
import DashKitUI
import SwiftUI
import UniformTypeIdentifiers

struct GCPSettings: View {
    @Bindable var gcp: GCPIntegration
    @State private var choosing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Credentials", value: gcp.credentialsPath.isEmpty ? "Application Default Credentials" : gcp.credentialsFile.lastPathComponent)
                HStack {
                    ConnectionStatusLabel(gcp.connectionState)
                    Spacer()
                    Button("Service Account Key…") { choosing = true }
                    if !gcp.credentialsPath.isEmpty { Button("Use Default") { gcp.credentialsPath = "" } }
                    AsyncButton("Check") {
                        gcp.reload()
                        await gcp.verify()
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Default: the file written once by `gcloud auth application-default login` (\(GoogleCredentials.defaultPath.path)). Dash refreshes tokens itself over HTTPS; nothing is executed.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { gcp.credentialsPath = url.path }
        }
    }
}
