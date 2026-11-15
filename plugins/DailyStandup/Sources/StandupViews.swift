import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

struct DailyStandupWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// me, meeting or blockers.
        var tab: String
    }

    static let kind = "daily-standup"
    static let displayName = "Daily Standup"
    static let summary = "Your update for today's standup (since yesterday, next steps, blockers), the Zoom standup followed live and its report, and open blockers."
    static let systemImage = "person.3.sequence"
    static let defaultSize = WidgetSize.large
    static let sizeLimits = GridLimits(minW: 4, minH: 6, maxW: 12, maxH: 24)
    static let defaultConfig = Config(tab: "me")
    static let configSchema: JSONValue = ["type": "object", "properties": ["tab": ["type": "string", "enum": ["me", "meeting", "blockers"]]]]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        StandupWidgetView(tab: config.tab, standup: context.host.ext(DailyStandupFeature.self))
    }

    static func preview(config: Config) -> some View {
        StandupUpdateView(update: StandupUpdate(
            yesterday: [StandupItem(text: "Finished the renewal endpoint and its tests", ticket: "LAF-5680", refs: ["a1b2c3d", "api#88"]),
                        StandupItem(text: "Reviewed Sam's checkout PR", ticket: "WEB-412", refs: ["web#412"])],
            today: [StandupItem(text: "Fix the flaky renewal test Claude flagged", ticket: "LAF-5680", refs: ["api#88"], kind: "fix"),
                    StandupItem(text: "Waiting for review on the renewal PR", ticket: "LAF-5680", refs: ["api#88"], kind: "waiting"),
                    StandupItem(text: "Proration on upgrade", ticket: "LAF-5702", refs: [], kind: "start")],
            blockers: [StandupItem(text: "QA workspace crash-loops (OOM)", ticket: "LAF-5680", refs: ["laf-5680"])]),
            preparedAt: .now, onRefresh: nil)
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let standup = context.host.ext(DailyStandupFeature.self), let day = standup.day() else { return ["prepared": false] }
        return ["update": .string(day.update?.text ?? ""), "report": .string(day.report?.summary ?? "")]
    }
}

private struct StandupWidgetView: View {
    @Binding var tab: String
    let standup: DailyStandupFeature?

    var body: some View {
        if let standup {
            VStack(alignment: .leading, spacing: 8) {
                // Short labels so the tabs fit a narrow widget; the Zoom note is in the help.
                Picker("View", selection: $tab) {
                    Text("Me").tag("me")
                    Text(standup.isZoomDay() ? "Meeting" : "Meeting (not on Zoom today)").tag("meeting")
                    Text("Blockers").tag("blockers")
                }
                .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case "meeting": MeetingView(standup: standup)
                case "blockers": BlockersView(standup: standup)
                default: MeView(standup: standup)
                }
            }
        } else {
            StateView(.failed(message: "Daily Standup isn't loaded."))
        }
    }
}

private struct MeView: View {
    let standup: DailyStandupFeature
    @State private var error: String?

    var body: some View {
        let _ = standup.revision
        let day = standup.day()
        VStack(alignment: .leading, spacing: 8) {
            if let update = day?.update {
                StandupUpdateView(update: update, preparedAt: day?.preparedAt) { refresh() }
            } else {
                ContentUnavailableView {
                    Label(standup.isWorkday() ? "Not prepared yet" : "No standup today", systemImage: "person.3.sequence")
                } description: {
                    Text("Prepared \(standup.prepareMinutesBefore) min before \(standup.time) from your commits, PRs, tickets, agents and deploys since the last standup.")
                } actions: {
                    Button("Prepare Now") { refresh() }.disabled(standup.isPreparing)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if standup.isPreparing { ProgressView("Preparing…").controlSize(.small) }
            if let error = error ?? standup.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func refresh() {
        Task {
            do { try await standup.prepare(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct StandupUpdateView: View {
    let update: StandupUpdate
    let preparedAt: Date?
    let onRefresh: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Yesterday I did", update.yesterday, icon: "checkmark.circle")
                section("Today I will", update.today, icon: nil)
                section("Blockers", update.blockers, icon: "exclamationmark.octagon")
                HStack {
                    if let preparedAt { Text("Prepared \(preparedAt.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary) }
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(update.text, forType: .string)
                    }
                    .help("Copy for Slack")
                    if let onRefresh { Button("Redo", systemImage: "arrow.clockwise", action: onRefresh) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [StandupItem], icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            if items.isEmpty { Text("Nothing").font(.callout).foregroundStyle(.tertiary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon ?? StandupItem.icon(item.kind)).foregroundStyle(title == "Blockers" ? .red : .accentColor).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if let ticket = item.ticket, !ticket.isEmpty { Text(ticket).font(.callout.monospaced().bold()) }
                            if let label = StandupItem.label(item.kind) { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
                            Text(item.text).font(.callout)
                        }
                        if !item.refs.isEmpty { Text(item.refs.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }
}

private struct MeetingView: View {
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

private struct LiveMeetingView: View {
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

private struct ReportView: View {
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

private struct BlockersView: View {
    let standup: DailyStandupFeature

    var body: some View {
        let _ = standup.revision
        let blockers = standup.openBlockers()
        if blockers.isEmpty {
            ContentUnavailableView("No open blockers", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(blockers) { blocker in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.text).font(.callout)
                        Text("\(blocker.owner) · open \(blocker.daysOpen) day\(blocker.daysOpen == 1 ? "" : "s")\(blocker.reference.isEmpty ? "" : " · \(blocker.reference)")")
                            .font(.caption).foregroundStyle(blocker.daysOpen >= 3 ? .red : .secondary)
                    }
                    Spacer()
                    Button("Resolved", systemImage: "checkmark.circle") { standup.resolve(blocker) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }
}

struct StandupSettings: View {
    @Bindable var standup: DailyStandupFeature
    private let days = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        Form {
            Section {
                TextField("Standup time", text: $standup.time, prompt: Text("10:00"))
                Stepper("Prepare my update \(standup.prepareMinutesBefore) min before", value: $standup.prepareMinutesBefore, in: 5...120, step: 5)
                dayToggles("Working days (an update every one)", $standup.workdays)
                dayToggles("On Zoom (followed and reported)", $standup.zoomDays)
            } header: {
                Text("When")
            } footer: {
                Text("Every working day you get your update: since the last standup, next steps, blockers. On Zoom days the meeting is also followed live and reported at the end.")
            }
            Section("You") {
                TextField("Your name in Zoom", text: $standup.myName)
                TextField("Your git email", text: $standup.gitEmail, prompt: Text("from each repository's git config"))
                TextField("Code folder", text: $standup.codeRoot, prompt: Text("~/Codes"))
            }
            Section {
                TextField("Meeting titles", text: $standup.keywords)
            } header: {
                Text("Which Zoom meeting is the standup")
            } footer: {
                Text("A meeting on a Zoom day within 45 minutes of the standup time, or whose title contains one of these words. Turn on Zoom captions so each line has its speaker's name.")
            }
        }
        .formStyle(.grouped)
    }

    private func dayToggles(_ title: String, _ selection: Binding<Set<Int>>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(days, id: \.0) { day, label in
                    Toggle(label, isOn: Binding(get: { selection.wrappedValue.contains(day) },
                                                set: { on in if on { selection.wrappedValue.insert(day) } else { selection.wrappedValue.remove(day) } }))
                        .toggleStyle(.button)
                }
            }
        }
    }
}
