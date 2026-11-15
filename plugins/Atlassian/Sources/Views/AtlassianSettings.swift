import DashKit
import DashKitUI
import SwiftUI

struct AtlassianSettings: View {
    @Bindable var atlassian: AtlassianIntegration

    var body: some View {
        Form {
            Section {
                TextField("Site", text: $atlassian.site, prompt: Text("https://your-team.atlassian.net"))
                TextField("Email", text: $atlassian.email)
                SecretField("API token", placeholder: "Create at id.atlassian.com", isStored: atlassian.hasToken,
                            onSave: { atlassian.setToken($0) }, onRemove: { atlassian.setToken("") })
                // Atlassian's page doesn't take pre-filled values: name it "Dash" there.
                Link("Create an API token at id.atlassian.com (name it “Dash”)",
                     destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!).font(.callout)
                HStack {
                    ConnectionStatusLabel(atlassian.connectionState)
                    Spacer()
                    AsyncButton("Check") { await atlassian.verify() }
                }
            } header: {
                Text("Account")
            } footer: {
                Link("Create an API token (used for Jira and Confluence)", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
            }
            AtlassianCacheSection(atlassian: atlassian)
        }
        .formStyle(.grouped)
    }
}
