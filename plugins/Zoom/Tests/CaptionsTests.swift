import DashKit
import Foundation
import SwiftData
import Testing

@MainActor
struct CaptionsTests {
    @Test func parsesCaptionRows() {
        #expect(ZoomAccessibility.captionLine(["Ada Lovelace", "10:02", "I finished the renewal API."])! == ("Ada Lovelace", "I finished the renewal API."))
        #expect(ZoomAccessibility.captionLine(["Sam (Host): blocked on the QA env"])! == ("Sam", "blocked on the QA env"))
        #expect(ZoomAccessibility.captionLine(["10:03"]) == nil)
    }
}

@MainActor
struct SpeakersTests {
    @Test func namedCaptionsGiveSpeakersAndReplaceOthers() throws {
        let (zoom, host) = makeZoom(myName: "Sadik")
        defer { _ = host }
        zoom.observe(inMeeting: true, participants: ["Sadik", "Ada", "Sam"])
        let meeting = try #require(zoom.beginMeeting())
        zoom.add(.init(speaker: "Sadik", text: "Yesterday I shipped the renewals."), to: meeting)
        zoom.add(.init(speaker: "Others", text: "i finished the api"), to: meeting)
        zoom.addCaptions([("Ada", "I finished the API."), ("Sam", "Blocked on QA.")], to: meeting)
        zoom.addCaptions([("Ada", "I finished the API."), ("Ada", "Today, tests.")], to: meeting)
        #expect(zoom.speakers(meeting).map(\.name) == ["Sadik", "Ada", "Sam"])
        #expect(zoom.speakers(meeting).first { $0.name == "Ada" }?.lines == 2)
        #expect(!zoom.namedSegments(meeting).contains { $0.speaker == "Others" })
    }
}
