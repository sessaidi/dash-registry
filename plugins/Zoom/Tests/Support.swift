import DashKit
import Foundation
import SwiftData

@MainActor
final class FakePermissions: PermissionAsking {
    func ask(icon: String, title: String, message: String, details: [PermissionDetail], allowLabel: String, denyLabel: String) async -> Bool { false }
}

/// Answers every request with `response` and keeps the prompts it was sent.
@MainActor
final class FakeClaude: ClaudeService {
    var response = ""
    private(set) var prompts: [String] = []
    var model: String { "test" }

    func complete(system: String, prompt: String, outputSchema: JSONValue?, effort: String?) async throws -> String {
        prompts.append(prompt)
        return response
    }
}

/// A host with an in-memory store holding the Zoom models.
@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let permissions: any PermissionAsking = FakePermissions()
    let fakeClaude = FakeClaude()
    var claude: any ClaudeService { fakeClaude }
    let activity = ActivityLog()
    private(set) var askedClaude: [String] = []

    init(_ extensions: [any DashExtension] = []) {
        let container = try! ModelContainer(
            for: Schema([MeetingRecord.self, TranscriptSegment.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askClaude(_ prompt: String) { askedClaude.append(prompt) }
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}

/// A Zoom extension on its own defaults suite, attached to a fresh host (no polling, no capture).
@MainActor
func makeZoom(myName: String = "Sadik", summarizeOnStop: Bool = false) -> (ZoomExtension, FakeHost) {
    let defaults = UserDefaults(suiteName: "zoom-tests-\(UUID().uuidString)")!
    defaults.set(myName, forKey: "zoom.myName")
    defaults.set(summarizeOnStop, forKey: "zoom.summarize")
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
    func tool(_ name: String) throws -> ClaudeTool {
        guard let tool = tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return tool
    }
}
