import DashKit
import SwiftUI

/// The feature's settings: default cycle and where reports are saved.
struct BackendMeetingSettings: View {
    @Bindable var feature: BackendMeetingFeature

    var body: some View {
        Form {
            Section {
                Picker("Default cycle", selection: $feature.defaultCycleWeeks) {
                    ForEach(1...10, id: \.self) { Text($0 == 1 ? "1 week" : "\($0) weeks").tag($0) }
                }
                TextField("Also save reports in", text: $feature.outputFolder, prompt: Text("Leave empty to keep them only in Dash"))
            } header: {
                Text("Reports")
            } footer: {
                Text("A report covers the time since the previous one (or the cycle when there's none). It reads your GitHub PRs, your Jira tickets and Dash's activity; nothing is written to GitHub or Jira.")
            }
        }
        .formStyle(.grouped)
    }
}
