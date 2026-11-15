import DashKit
import DashKitUI
import SwiftUI

/// The Kubernetes pane in Settings/Extensions: kubeconfig, context, namespace and status.
struct KubernetesSettings: View {
    @Bindable var kubernetes: KubernetesIntegration

    var body: some View {
        Form {
            Section {
                LabeledContent("kubeconfig") {
                    Text(kubernetes.configURL.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                if !kubernetes.contextNames.isEmpty {
                    Picker("Context", selection: $kubernetes.selectedContext) {
                        Text("current-context" + (kubernetes.config?.currentContext.map { " (\($0))" } ?? "")).tag("")
                        ForEach(kubernetes.contextNames, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Namespace", text: $kubernetes.namespaceSetting, prompt: Text(kubernetes.resolved?.namespace ?? "default"))
                if let resolved = kubernetes.resolved {
                    LabeledContent("Server") { Text(resolved.server.absoluteString).textSelection(.enabled) }
                    LabeledContent("Authentication", value: resolved.auth.isSupported ? authLabel(resolved) : "Unsupported")
                    LabeledContent("Trust", value: resolved.insecure ? "Not verified" : resolved.certificateAuthorities.isEmpty ? "System roots" : "Cluster CA")
                    if resolved.insecure {
                        Label("TLS verification is off for this cluster (insecure-skip-tls-verify). Anyone on the network path can impersonate it and read your credentials.",
                              systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(Tone.warning.color)
                    }
                    if kubernetes.needsGoogle, !kubernetes.googleAvailable {
                        Label("This context uses gke-gcloud-auth-plugin. Connect the Google Cloud integration and Dash will use its token instead.",
                              systemImage: "cloud")
                            .foregroundStyle(Tone.warning.color)
                    }
                }
                HStack {
                    ConnectionStatusLabel(kubernetes.connectionState)
                    Spacer()
                    Button("Reload kubeconfig") { kubernetes.reload(); Task { await kubernetes.verify() } }
                    AsyncButton("Check") { await kubernetes.verify() }
                }
            } header: {
                Text("Cluster")
            } footer: {
                Text("Dash reads $KUBECONFIG (first file) or ~/.kube/config itself; nothing is executed. Supported: tokens, token files, basic auth, client certificates (RSA/ECDSA), and gke-gcloud-auth-plugin through Google Cloud. Other exec plugins (aws, kubelogin…) aren't.")
            }
        }
        .formStyle(.grouped)
    }

    private func authLabel(_ resolved: ResolvedContext) -> String {
        let base = resolved.auth.summary
        return resolved.clientCertificate != nil ? (resolved.auth == .none ? "client certificate" : "client certificate + \(base)") : base
    }
}
