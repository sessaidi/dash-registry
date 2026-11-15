import DashKit
import DashKitUI
import SwiftUI

/// The GitLab pane in Settings/Extensions: instance, token, status and watched projects.
struct GitLabSettingsView: View {
    @Bindable var gitlab: GitLabIntegration

    var body: some View {
        Form {
            Section {
                TextField("Instance", text: $gitlab.instanceURL, prompt: Text(GitLabIntegration.defaultInstance))
                SecretField("Personal access token", placeholder: "glpat-…", isStored: gitlab.hasToken,
                            onSave: { gitlab.setToken($0) }, onRemove: { gitlab.setToken("") })
                // GitLab fills in the name and ticks the scopes from the URL.
                if let url = URL(string: gitlab.instanceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                                 + "/-/user_settings/personal_access_tokens?name=Dash&scopes=read_api,read_repository,read_user") {
                    Link("Create a token (name and scopes filled in: read_api, read_repository, read_user)", destination: url).font(.callout)
                }
                HStack {
                    ConnectionStatusLabel(gitlab.connectionState)
                    Spacer()
                    AsyncButton("Check") { await gitlab.verify() }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Token scope read_api is enough to read; api to comment or approve.")
            }
            Section {
                TextEditor(text: $gitlab.projectsText).font(.body.monospaced()).frame(height: 80)
            } header: {
                Text("Watched projects")
            } footer: {
                Text("group/project, one per line.")
            }
            FeaturesUsingSection(integrationID: gitlab.id, host: gitlab.host)
        }
    }
}
