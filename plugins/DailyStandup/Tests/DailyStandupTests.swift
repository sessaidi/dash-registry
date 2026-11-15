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
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start(host: any ExtensionContext) {}
    var tools: [DashiiTool] {
        let started = meetingStart.formatted(.iso8601)
        return [
            DashiiTool(name: "meetings_list", description: "") { _ in [["id": "m1", "title": "Daily standup", "started": .string(started)]] },
            DashiiTool(name: "meeting_transcript", description: "") { _ in
                ["id": "m1", "started": .string(started), "participants": ["Sadik", "Ada", "Sam"],
                 "transcript": "[00:05] Sadik: Yesterday I finished LAF-12.\n[00:40] Ada: Today I review it.\n[01:10] Sam: Blocked on the QA env."]
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
        for arguments in [["init", "-q", "-b", "feat/laf-12-renew"], ["config", "user.email", "me@example.com"], ["config", "user.name", "Me"],
                          ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "LAF-12 renewal endpoint"]] {
            _ = StandupGit.git(repo, arguments)
        }
        #expect(StandupGit.git(repo, ["log", "--oneline"])?.contains("LAF-12") == true, "commit: \(StandupGit.git(repo, ["status"]) ?? "nil")")
        standup.codeRoot = codes.path
        let since = Date.now.addingTimeInterval(-3600)
        let evidence = await standup.evidence(since: since)
        #expect(evidence["commits"]?.array?.first?["subject"]?.string == "LAF-12 renewal endpoint")
        #expect(evidence["commits"]?.array?.first?["repo"]?.string == "api")

        host.testDashii.reply = #"""
            {"yesterday":[{"ticket":"LAF-12","text":"Finished the renewal endpoint","refs":["abc1234"]}],
             "today":[{"ticket":"LAF-12","text":"Fix the failing proration test","refs":["api#8"],"kind":"fix"},
                      {"ticket":"LAF-20","text":"Proration on upgrade","refs":[],"kind":"start"}],
             "blockers":[{"ticket":"LAF-12","text":"QA workspace keeps restarting","refs":["laf-12"]}]}
            """#
        let update = try await standup.prepare()
        #expect(update.text.contains("*Yesterday I did*\n• LAF-12 — Finished the renewal endpoint (abc1234)"))
        #expect(update.text.contains("• LAF-12 — Fix: Fix the failing proration test (api#8)"))
        #expect(update.text.contains("• LAF-20 — Start: Proration on upgrade"))
        #expect(standup.day()?.preparedAt != nil)
        #expect(standup.openBlockers().map(\.text) == ["QA workspace keeps restarting"])
        #expect(host.activity.events.contains { $0.kind == "standup.prepared" })
        // The prompt asked for tickets and the kinds of next step.
        let call = try #require(host.testDashii.calls.last)
        #expect(call.system.contains("Yesterday I did") && call.prompt.contains("LAF-12 renewal endpoint"))
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
             "people":[{"name":"Sadik","yesterday":["Finished LAF-12"],"today":[],"blockers":[]},
                       {"name":"Sam","yesterday":[],"today":[],"blockers":["QA env"]}],
             "blockers":[{"owner":"Sam","task":"QA env down"}],
             "actionItems":[{"owner":"Ada","task":"Review LAF-12"}]}
            """#
        let report = try await standup.report(meetingID: "m1")
        #expect(report.namesFromCaptions && report.people.first { $0.name == "Sadik" }?.words == 6)
        #expect(standup.day()?.report?.actionItems == [MeetingReport.Action(owner: "Ada", task: "Review LAF-12")])
        #expect(host.notes.first?.folder == "Standups" && host.notes.first?.markdown.contains("- [ ] Ada: Review LAF-12") == true)
        #expect(standup.openBlockers().contains { $0.owner == "Sam" })
        #expect(host.testDashii.calls.last?.system.contains("Lines carry each speaker's name") == true)
    }
}
