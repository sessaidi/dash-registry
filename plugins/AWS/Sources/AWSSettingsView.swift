import DashKit
import DashKitUI
import SwiftUI

/// The AWS pane in Settings/Extensions: profile, region override and status.
struct AWSSettingsView: View {
    @Bindable var aws: AWSIntegration

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: $aws.profileName) {
                    if aws.profile == nil { Text(aws.profileName).tag(aws.profileName) }
                    ForEach(aws.profiles, id: \.name) { profile in
                        Text(profile.isSSO ? "\(profile.name) (SSO)" : profile.name).tag(profile.name)
                    }
                }
                TextField("Region", text: $aws.regionOverride, prompt: Text(aws.profile?.region ?? "us-east-1"))
                HStack {
                    ConnectionStatusLabel(aws.connectionState)
                    Spacer()
                    AsyncButton("Check") { await aws.reload() }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Reads ~/.aws/config and ~/.aws/credentials. SSO profiles use the login cached by `aws sso login`; Dash signs requests itself and runs nothing.")
            }
            FeaturesUsingSection(integrationID: aws.id, host: aws.host)
        }
    }
}
