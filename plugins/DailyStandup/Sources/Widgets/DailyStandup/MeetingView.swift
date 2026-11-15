import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The Zoom standup: followed live while it runs, then its report.
struct MeetingView: View {
    let standup: DailyStandupFeature

    var body: some View {
        let _ = standup.revision
        let day = standup.day()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let live = standup.live, live["meeting_id"] != nil, day?.report == nil {
                    LiveMeetingView(live: live, me: standup.myName)
                } else if let report = day?.report {
                    ReportView(report: report, notePath: day?.notePath ?? "")
                } else if !standup.isZoomDay() {
                    Text("Today's standup isn't on Zoom (Settings › Daily Standup › Zoom days). Your own update is under Me.").foregroundStyle(.secondary)
                } else {
                    Text("The standup at \(standup.time) is followed here while it runs, and reported when it ends. Turn on Zoom's captions so each line has its speaker's name.")
                        .foregroundStyle(.secondary)
                }
                if standup.isReporting { ProgressView("Writing the report…").controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Who spoke and who hasn't yet, while the standup runs.
struct LiveMeetingView: View {
    let live: JSONValue
    let me: String

    var body: some View {
        let speakers = live["speakers"]?.array ?? []
        let notHeard = (live["not_heard_yet"]?.array ?? []).compactMap(\.string)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Live").font(.caption.bold())
                if let now = live["speaking_now"]?.string { Text("· \(now) is speaking").font(.callout) }
            }
            ForEach(Array(speakers.enumerated()), id: \.offset) { index, speaker in
                HStack {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(speaker["name"]?.string ?? "").font(.callout.weight(speaker["name"]?.string == live["speaking_now"]?.string ? .bold : .regular))
                    Spacer()
                    Text("\(speaker["words"]?.int ?? 0) words").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !notHeard.isEmpty {
                Text("Not heard yet: \(notHeard.joined(separator: ", "))").font(.caption).foregroundStyle(notHeard.contains(me) ? .orange : .secondary)
                if notHeard.contains(me) && notHeard.count <= 2 { Label("You're up soon", systemImage: "hand.raised").font(.callout.bold()).foregroundStyle(.orange) }
            }
            if live["named"]?.bool != true {
                Text("Zoom captions are off: only your own lines carry a name. Turn on captions (or the live transcript) to follow who speaks.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The standup's report: each person's update, action items.
struct ReportView: View {
    let report: MeetingReport
    let notePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.summary).font(.callout)
            ForEach(report.people, id: \.name) { person in
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name + (person.words.map { " · \($0) words" } ?? "")).font(.callout.bold())
                    if !person.yesterday.isEmpty { Text("Did: " + person.yesterday.joined(separator: "; ")).font(.caption) }
                    if !person.today.isEmpty { Text("Next: " + person.today.joined(separator: "; ")).font(.caption) }
                    if !person.blockers.isEmpty { Text("Blocked: " + person.blockers.joined(separator: "; ")).font(.caption).foregroundStyle(.red) }
                }
            }
            if !report.actionItems.isEmpty {
                Text("Action items").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(report.actionItems, id: \.self) { Text("• \($0.owner): \($0.task)").font(.caption) }
            }
            if !report.notHeard.isEmpty { Text("Didn't speak: \(report.notHeard.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            if !report.namesFromCaptions { Text("Speakers attributed from the conversation (Zoom captions were off).").font(.caption2).foregroundStyle(.tertiary) }
            if !notePath.isEmpty {
                Button("Open Note") { NSWorkspace.shared.open(URL(fileURLWithPath: notePath)) }.buttonStyle(.link)
            }
        }
    }
}
