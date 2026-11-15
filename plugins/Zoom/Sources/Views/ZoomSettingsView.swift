import AppKit
import DashKit
import SwiftUI

/// Transcription, recording and permission settings.
struct ZoomSettingsView: View {
    @Bindable var zoom: ZoomExtension

    var body: some View {
        Form {
            Section("Transcription") {
                TextField("Your name", text: $zoom.myName)
                TextField("Language", text: $zoom.localeIdentifier, prompt: Text("en_US"))
                Toggle("Start transcribing when a Zoom meeting starts", isOn: $zoom.autoStart)
                Toggle("Summarise with Dashii when the meeting ends", isOn: $zoom.summarizeOnStop)
            }
            Section {
                Toggle("Save the meeting's audio", isOn: $zoom.saveAudio)
                Toggle("Also record video of Zoom's windows", isOn: $zoom.recordVideo)
                    .disabled(!zoom.saveAudio)
                LabeledContent("Folder") {
                    HStack {
                        Text(zoom.recordingsFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: zoom.recordingsFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(zoom.recordingsFolder)
                        }
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Audio is saved as an .m4a with two tracks, Zoom and your microphone. With video it is a .mov of Zoom's windows on the screen showing the meeting (other apps are left out), at up to 1920 pixels and 15 frames a second. Files stay on this Mac.")
            }
            Section {
                LabeledContent("Accessibility") {
                    if ZoomAccessibility.isTrusted { Text("Granted").foregroundStyle(.green) } else {
                        Button("Grant…") { ZoomAccessibility.requestTrust() }
                    }
                }
                LabeledContent("Screen & system audio recording") {
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility reads Zoom's meeting window and Participants panel. Screen recording permission lets Dash capture Zoom's audio and windows. Speech is transcribed on this Mac; the transcript goes to Dashii only when summarising or when you ask about it.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = zoom.recordingsFolder
        if panel.runModal() == .OK, let url = panel.url { zoom.recordingsFolder = url }
    }
}
