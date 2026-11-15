import DashKit
import DashKitUI
import SwiftUI

/// The Datadog pane in Settings/Extensions: site, keys and status.
struct DatadogSettings: View {
    @Bindable var integration: DatadogIntegration

    var body: some View {
        Form {
            Section {
                Picker("Site", selection: $integration.site) {
                    ForEach(DatadogIntegration.sites, id: \.self) { Text($0).tag($0) }
                    if !DatadogIntegration.sites.contains(integration.site) { Text(integration.site).tag(integration.site) }
                }
                SecretField("API key", isStored: integration.secrets?.contains("api_key") == true,
                            onSave: { integration.setKey("api_key", $0) }, onRemove: { integration.setKey("api_key", "") })
                SecretField("Application key", isStored: integration.secrets?.contains("app_key") == true,
                            onSave: { integration.setKey("app_key", $0) }, onRemove: { integration.setKey("app_key", "") })
                HStack {
                    ConnectionStatusLabel(integration.connectionState)
                    Spacer()
                    AsyncButton("Check") { await integration.verify() }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Keys come from Organization Settings › API Keys and Application Keys. Give the application key read-only scopes: Dash only reads (monitors, metrics, logs, events, incidents, dashboards, SLOs, hosts, services) and never changes Datadog.")
            }
        }
        .formStyle(.grouped)
    }
}
