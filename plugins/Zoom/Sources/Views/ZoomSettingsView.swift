import AppKit
import DashKit
import SwiftUI

/// Transcription, recording and permission settings.
struct ZoomSettingsView: View {
    @Bindable var zoom: ZoomExtension
    @State private var captured: URL?
    @State private var captureError: String?

    var body: some View {
        Form {
            Section("Transcription") {
                TextField("Your name", text: $zoom.myName)
                TextField("Language", text: $zoom.localeIdentifier, prompt: Text("en_US"))
                Toggle("Record automatically when I join a Zoom meeting", isOn: $zoom.autoStart)
                    .help("Stops by itself when the meeting ends. If you press Stop, it waits for the next meeting.")
                Toggle("Open Zoom's transcript when recording starts", isOn: $zoom.openTranscript)
                    .help("Zoom's transcript names every speaker; Dash reads it (needs Accessibility, and the host may have to allow captions).")
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
                if zoom.calendarAccess == .denied {
                    LabeledContent("Calendar") {
                        Button("Open Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                } else {
                    Toggle("Read Zoom meetings from my calendar", isOn: Binding(
                        get: { zoom.useCalendar },
                        set: { on in if on { Task { await zoom.enableCalendar() } } else { zoom.useCalendar = false } }))
                }
                Stepper("Remind me \(zoom.reminderMinutes) min before", value: $zoom.reminderMinutes, in: 0...30)
                    .disabled(!zoom.useCalendar)
            } header: {
                Text("Calendar")
            } footer: {
                Text("Reads the Mac's calendars (Google, Outlook or iCloud, as synced to Calendar) for events with a Zoom link: the Upcoming Meetings widget, a recording named after its event, and a `zoom.meeting_soon` event for hooks and notifications. Nothing leaves this Mac.")
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
                LabeledContent("Zoom's window structure") {
                    HStack {
                        Button("Capture") { capture() }
                            .disabled(!ZoomAccessibility.isTrusted || !zoom.isZoomRunning)
                        if let captured { Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([captured]) } }
                    }
                }
                .help("During a meeting, saves what Dash can see of Zoom's windows to a text file next to the recordings, to build readers for the active speaker, the chat and who joins or leaves.")
                if let captureError { Text(captureError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility reads Zoom's meeting window and Participants panel. Screen recording permission lets Dash capture Zoom's audio and windows. Speech is transcribed on this Mac; the transcript goes to Dashii only when summarising or when you ask about it.")
            }
        }
    }

    private func capture() {
        do {
            captured = try zoom.captureStructure()
            captureError = nil
            if let captured { NSWorkspace.shared.activateFileViewerSelecting([captured]) }
        } catch {
            captureError = error.localizedDescription
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
