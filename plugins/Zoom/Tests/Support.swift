import DashKit
import Foundation
import SwiftData

/// Declines every prompt and keeps their titles; yields first, like a sheet the user answers later.
@MainActor
final class FakePermissions: PermissionAsking {
    private(set) var asked: [String] = []

    func ask(_ prompt: PermissionPrompt) async -> Bool {
        asked.append(prompt.title)
        await Task.yield()
        return false
    }
}

/// Answers every request with `response` and keeps the prompts it was sent.
@MainActor
final class FakeDashii: DashiiService {
    var response = ""
    private(set) var prompts: [String] = []
    var model: String { "test" }

    func complete(_ request: DashiiRequest) async throws -> String {
        prompts.append(request.prompt)
        return response
    }
}

/// A host with an in-memory store holding the Zoom models.
@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let fakePermissions = FakePermissions()
    var permissions: any PermissionAsking { fakePermissions }
    let fakeDashii = FakeDashii()
    var dashii: any DashiiService { fakeDashii }
    let activity = ActivityLog()
    private(set) var askedDashii: [String] = []

    init(_ extensions: [any DashExtension] = []) {
        let container = try! ModelContainer(
            for: Schema([MeetingRecord.self, TranscriptSegment.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askDashii(_ prompt: String) { askedDashii.append(prompt) }
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}

/// A Zoom extension on its own defaults suite, attached to a fresh host (no polling, no capture).
@MainActor
func makeZoom(myName: String = "Sadik", summarizeOnStop: Bool = false) -> (ZoomExtension, FakeHost) {
    let defaults = UserDefaults(suiteName: "zoom-tests-\(UUID().uuidString)")!
    defaults.set(myName, forKey: "zoom.myName")
    defaults.set(summarizeOnStop, forKey: "zoom.summarize")
    // Recording for real needs permissions: tests start meetings themselves.
    defaults.set(false, forKey: "zoom.autoRecord")
    let zoom = ZoomExtension(defaults: defaults)
    let host = FakeHost([zoom])
    zoom.attach(host)
    return (zoom, host)
}

/// A stored meeting with transcript lines `seconds` after its start.
@MainActor
@discardableResult
func insertMeeting(_ host: FakeHost, title: String, startedAt: Date, lines: [(seconds: Double, speaker: String, text: String)] = []) -> MeetingRecord {
    let meeting = MeetingRecord(title: title)
    meeting.startedAt = startedAt
    host.context.insert(meeting)
    for line in lines {
        let segment = TranscriptSegment(meetingID: meeting.id, speaker: line.speaker, text: line.text)
        segment.createdAt = startedAt.addingTimeInterval(line.seconds)
        host.context.insert(segment)
    }
    try! host.context.save()
    return meeting
}

extension ZoomExtension {
    func tool(_ name: String) throws -> DashiiTool {
        guard let tool = tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return tool
    }
}
