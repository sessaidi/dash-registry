import DashKit
import DashKitTesting
import Foundation
import SwiftData
import SwiftUI
import Testing

/// A Zoom stand-in: the meeting tools the standup reads.
@MainActor
private final class FakeZoom: DashExtension {
    let id = "zoom"
    let name = "Zoom"
    let systemImage = "video"
    var meetingStart = Date.now
    /// What `zoom_upcoming_meetings` returns: the calendar.
    var upcoming: [JSONValue] = []
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start(host: any ExtensionContext) {}
    var tools: [DashiiTool] {
        let started = meetingStart.formatted(.iso8601)
        let upcoming = upcoming
        return [
            DashiiTool(name: "zoom_upcoming_meetings", description: "") { _ in ["calendar": true, "meetings": .array(upcoming)] },
            DashiiTool(name: "meetings_list", description: "") { _ in [["id": "m1", "title": "Daily standup", "started": .string(started)]] },
            DashiiTool(name: "meeting_transcript", description: "") { _ in
                ["id": "m1", "started": .string(started), "participants": ["Sadik", "Ada", "Sam"],
                 "transcript": "[00:05] Sadik: Yesterday I finished KAN-12.\n[00:40] Ada: Today I review it.\n[01:10] Sam: Blocked on the QA env."]
            },
            DashiiTool(name: "meeting_speakers", description: "") { _ in
                ["meeting_id": "m1", "named": true, "speakers": [["name": "Sadik", "words": 6], ["name": "Ada", "words": 5], ["name": "Sam", "words": 5]],
                 "not_heard_yet": []]
            },
        ]
    }
}

@MainActor
struct DailyStandupTests {
    private func make() throws -> (DailyStandupFeature, FakeZoom, TestHost) {
        let standup = DailyStandupFeature(defaults: UserDefaults(suiteName: "standup-\(UUID().uuidString)")!)
        let zoom = FakeZoom()
        let host = try TestHost([zoom, standup])
        host.start([zoom, standup])
        standup.stop()
        standup.myName = "Sadik"
        return (standup, zoom, host)
    }

    private static func event(_ title: String, at start: Date, link: String? = "https://acme.zoom.us/j/1") -> JSONValue {
        ["title": .string(title), "start": .string(start.formatted(.iso8601)), "end": .string(start.addingTimeInterval(900).formatted(.iso8601)),
         "calendar": "Work", "join_url": link.map(JSONValue.string) ?? .null]
    }

    @Test func theCalendarSetsTheStandupTimeAndLink() async throws {
        let (standup, zoom, host) = try make()
        defer { _ = host }
        standup.workdays = Set(1...7)
        standup.zoomDays = []
        let now = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!  // whole seconds: ISO 8601 drops the rest
        let start = now.addingTimeInterval(95 * 60)
        zoom.upcoming = [Self.event("1:1 with Ada", at: now.addingTimeInterval(30 * 60)), Self.event("Team Daily", at: start)]
        await standup.refreshCalendar(now: now)
        #expect(standup.standupDate(on: now) == start)
        #expect(standup.calendarStandup(on: now)?.joinURL?.absoluteString == "https://acme.zoom.us/j/1")
        // A calendar standup with a Zoom link makes it a Zoom day, whatever the weekdays say.
        #expect(standup.isZoomDay(now))
        // Kept once the event is over (the calendar lists only what's ahead) and across launches.
        zoom.upcoming = []
        await standup.refreshCalendar(now: now.addingTimeInterval(600))
        #expect(standup.standupDate(on: now) == start)
        standup.useCalendar = false
        #expect(standup.standupDate(on: now) != start && !standup.isZoomDay(now))
    }

    @Test func meetingsNotTitledLikeAStandupAreIgnored() async throws {
        let (standup, zoom, host) = try make()
        defer { _ = host }
        let now = Date.now
        zoom.upcoming = [Self.event("Design review", at: now.addingTimeInterval(600))]
        await standup.refreshCalendar(now: now)
        #expect(standup.calendarStandup(on: now) == nil)
    }

    @Test func previousWorkdayOfMondayIsFriday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = ISO8601DateFormatter().date(from: "2026-11-16T09:00:00Z")!
        let friday = StandupDayKey.previousWorkday(before: monday, workdays: [2, 3, 4, 5, 6], calendar: calendar)
        #expect(StandupDayKey.key(friday, calendar: calendar) == "2026-11-13")
    }

    @Test func preparesTheUpdateWithTicketsNextStepsAndBlockers() async throws {
        let (standup, _, host) = try make()
        // A clone with one of my commits since the last workday.
        let codes = FileManager.default.temporaryDirectory.appending(path: "codes-\(UUID().uuidString)")
        let repo = codes.appending(path: "api")
        defer { try? FileManager.default.removeItem(at: codes) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "feat/kan-12-renew"], ["config", "user.email", "me@example.com"], ["config", "user.name", "Me"],
                          ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "KAN-12 renewal endpoint"]] {
            _ = StandupGit.git(repo, arguments)
        }
        #expect(StandupGit.git(repo, ["log", "--oneline"])?.contains("KAN-12") == true, "commit: \(StandupGit.git(repo, ["status"]) ?? "nil")")
        standup.codeRoot = codes.path
        let since = Date.now.addingTimeInterval(-3600)
        let evidence = await standup.evidence(since: since)
        #expect(evidence["commits"]?.array?.first?["subject"]?.string == "KAN-12 renewal endpoint")
        #expect(evidence["commits"]?.array?.first?["repo"]?.string == "api")

        host.testDashii.reply = #"""
            {"yesterday":[{"ticket":"KAN-12","text":"Finished the renewal endpoint","refs":["abc1234"]}],
             "today":[{"ticket":"KAN-12","text":"Fix the failing proration test","refs":["api#8"],"kind":"fix"},
                      {"ticket":"KAN-20","text":"Proration on upgrade","refs":[],"kind":"start"}],
             "blockers":[{"ticket":"KAN-12","text":"QA workspace keeps restarting","refs":["kan-12"]}]}
            """#
        let update = try await standup.prepare()
        #expect(update.text.contains("*Yesterday I did*\n• KAN-12 — Finished the renewal endpoint (abc1234)"))
        #expect(update.text.contains("• KAN-12 — Fix: Fix the failing proration test (api#8)"))
        #expect(update.text.contains("• KAN-20 — Start: Proration on upgrade"))
        #expect(standup.day()?.preparedAt != nil)
        #expect(standup.openBlockers().map(\.text) == ["QA workspace keeps restarting"])
        #expect(host.activity.events.contains { $0.kind == "standup.prepared" })
        // The prompt asked for tickets and the kinds of next step.
        let call = try #require(host.testDashii.calls.last)
        #expect(call.system.contains("Yesterday I did") && call.prompt.contains("KAN-12 renewal endpoint"))
        // Mentioned again tomorrow: the same blocker, not a new one.
        standup.remember("QA workspace keeps restarting", owner: "Sadik")
        #expect(standup.openBlockers().count == 1)
    }

    @Test func reportsAZoomStandup() async throws {
        let (standup, zoom, host) = try make()
        zoom.meetingStart = standup.standupDate()
        standup.zoomDays = [Calendar.current.component(.weekday, from: .now)]
        standup.workdays = standup.zoomDays
        #expect(standup.isStandup(title: "Weekly sync", started: standup.standupDate()))
        host.testDashii.reply = #"""
            {"summary":"Renewals shipped; QA env blocks Sam.",
             "people":[{"name":"Sadik","yesterday":["Finished KAN-12"],"today":[],"blockers":[]},
                       {"name":"Sam","yesterday":[],"today":[],"blockers":["QA env"]}],
             "blockers":[{"owner":"Sam","task":"QA env down"}],
             "actionItems":[{"owner":"Ada","task":"Review KAN-12"}]}
            """#
        let report = try await standup.report(meetingID: "m1")
        #expect(report.namesFromCaptions && report.people.first { $0.name == "Sadik" }?.words == 6)
        #expect(standup.day()?.report?.actionItems == [MeetingReport.Action(owner: "Ada", task: "Review KAN-12")])
        #expect(host.notes.first?.folder == "Standups" && host.notes.first?.markdown.contains("- [ ] **Ada**: Review KAN-12") == true)
        #expect(standup.openBlockers().contains { $0.owner == "Sam" })
        #expect(host.testDashii.calls.last?.system.contains("Lines carry each speaker's name") == true)
    }
}
