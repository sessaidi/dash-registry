import DashKit
import Foundation
import Testing

/// Upcoming meetings from the calendar: Zoom links, joining, reminders and recording names.
@MainActor
struct CalendarTests {
    private func meeting(_ title: String, in minutes: Double, length: Double = 30, now: Date = .now) -> CalendarMeeting {
        CalendarMeeting(id: title, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                        calendar: "Work", joinURL: URL(string: "https://acme.zoom.us/j/123456789?pwd=abc"))
    }

    @Test func findsZoomLinksInEventText() {
        #expect(ZoomCalendar.zoomLink(in: ["Room 4", "Join: https://acme.zoom.us/j/987654321?pwd=xYz. See you"])?.absoluteString
                == "https://acme.zoom.us/j/987654321?pwd=xYz.")
        #expect(ZoomCalendar.zoomLink(in: ["<a href=\"https://zoom.us/my/ada\">Zoom</a>"])?.absoluteString == "https://zoom.us/my/ada")
        #expect(ZoomCalendar.zoomLink(in: ["zoommtg://zoom.us/join?confno=1"])?.scheme == "zoommtg")
        #expect(ZoomCalendar.zoomLink(in: ["https://meet.google.com/abc", "https://notzoom.com/j/1"]) == nil)
    }

    @Test func joinLinksOpenTheZoomApp() {
        let app = ZoomCalendar.appURL(for: URL(string: "https://acme.zoom.us/j/123456789?pwd=abc")!)
        #expect(app.absoluteString == "zoommtg://acme.zoom.us/join?action=join&confno=123456789&pwd=abc")
        let personal = URL(string: "https://zoom.us/my/ada")!
        #expect(ZoomCalendar.appURL(for: personal) == personal)
    }

    @Test func remindsOnceBeforeTheStart() {
        let (zoom, host) = makeZoom()
        let now = Date.now
        zoom.upcoming = [meeting("Design review", in: 1.5, now: now), meeting("Later", in: 60, now: now)]
        zoom.remind(now: now)
        zoom.remind(now: now.addingTimeInterval(20))
        #expect(host.activity.events.filter { $0.kind == "zoom.meeting_soon" }.count == 1)
        #expect(host.activity.events.last?.title.hasPrefix("Design review") == true)
    }

    @Test func aRecordingIsNamedAfterTheEventOnNow() throws {
        let (zoom, host) = makeZoom()
        zoom.upcoming = [meeting("Sprint planning", in: -3)]
        let id = try #require(zoom.beginMeeting())
        #expect(zoom.meeting(id)?.title == "Sprint planning")
        #expect(host.activity.events.last?.kind == "meeting.started")
        let (other, otherHost) = makeZoom()
        other.upcoming = [meeting("Tomorrow", in: 600)]
        let plain = try #require(other.beginMeeting())
        #expect(other.meeting(plain)?.title.hasPrefix("Zoom meeting") == true)
        _ = otherHost
    }

    @Test func dashiiReadsTheUpcomingMeetings() async throws {
        let (zoom, _) = makeZoom()
        zoom.upcoming = [meeting("Standup", in: 10)]
        let result = try await zoom.tool("zoom_upcoming_meetings").run([:])
        #expect(result["meetings"]?.array?.first?["title"]?.string == "Standup")
    }
}
