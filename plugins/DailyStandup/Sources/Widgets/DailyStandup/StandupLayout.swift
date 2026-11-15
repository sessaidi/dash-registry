import DashKit
import DashKitUI
import SwiftUI

/// An open blocker as the widget shows it; decoupled from SwiftData so previews can use samples.
struct StandupBlockerRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let owner: String
    let reference: String
    let daysOpen: Int

    var subtitle: String {
        "\(owner) · open \(daysOpen) day\(daysOpen == 1 ? "" : "s")\(reference.isEmpty ? "" : " · \(reference)")"
    }
}

/// Everything the widget shows about today's standup, read from the feature or from samples.
struct StandupState: Equatable {
    var update: StandupUpdate?
    var preparedAt: Date?
    /// Without an update: "Not prepared yet", or why there's no standup today.
    var unpreparedTitle = "Not prepared yet"
    var time = "09:30"
    var prepareMinutesBefore = 15
    var isZoomDay = true
    var isPreparing = false
    var isReporting = false
    var error: String?
    /// The standup being followed live (`meeting_speakers`), while it runs and before its report.
    var live: JSONValue?
    var myName = ""
    var report: MeetingReport?
    var notePath = ""
    var blockers: [StandupBlockerRow] = []

    var prepareHint: String {
        "Prepared \(prepareMinutesBefore) min before \(time) from your commits, PRs, tickets, agents and deploys since the last standup."
    }

    /// Whether `live` says I haven't spoken yet and I'm among the last two.
    var upSoon: Bool {
        let notHeard = (live?["not_heard_yet"]?.array ?? []).compactMap(\.string)
        return notHeard.contains(myName) && notHeard.count <= 2
    }

    /// Blockers open three days or more.
    var staleBlockers: Int { blockers.count { $0.daysOpen >= 3 } }
}

/// What the widget's buttons do; nil or no-ops in the gallery.
struct StandupCommands {
    /// Prepares (or redoes) today's update; nil hides Redo.
    var prepare: (() -> Void)?
    var resolve: (UUID) -> Void = { _ in }
}

/// The Daily Standup widget at any size: one layout per size family, live or from samples.
///
/// - narrow: my update's state (or Prepare Now), the standup's live/report state and the blocker count.
/// - medium: the Me / Meeting / Blockers tabs.
/// - wide: Me | Meeting | Blockers side by side.
/// - large: a summary strip, then my update beside the meeting and the blockers.
struct StandupLayout: View {
    let state: StandupState
    @Binding var tab: String
    var commands = StandupCommands()
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        switch layout.family {
        case .narrow:
            StandupGlance(state: state, commands: commands)
        case .wide:
            HStack(alignment: .top, spacing: 12) {
                StandupColumn("Me", systemImage: "person") { MeSection(state: state, commands: commands) }
                Divider()
                StandupColumn("Meeting", systemImage: "video", note: state.isZoomDay ? state.time : "Not on Zoom") { MeetingSection(state: state) }
                Divider()
                StandupColumn("Blockers", systemImage: "exclamationmark.octagon", note: "\(state.blockers.count)") {
                    BlockersSection(blockers: state.blockers, resolve: commands.resolve)
                }
            }
        case .large:
            VStack(alignment: .leading, spacing: 10) {
                StandupSummary(state: state)
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    StandupColumn("Me", systemImage: "person") { MeSection(state: state, commands: commands) }
                        .frame(maxWidth: .infinity)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        StandupColumn("Meeting", systemImage: "video", note: state.isZoomDay ? state.time : "Not on Zoom") { MeetingSection(state: state) }
                        Divider()
                        StandupColumn("Blockers", systemImage: "exclamationmark.octagon", note: "\(state.blockers.count)") {
                            BlockersSection(blockers: state.blockers, resolve: commands.resolve)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        default:
            switch tab {
            case "meeting": MeetingSection(state: state)
            case "blockers": BlockersSection(blockers: state.blockers, resolve: commands.resolve)
            default: MeSection(state: state, commands: commands)
            }
        }
    }
}

/// Medium's Me / Meeting / Blockers picker, in the card's header.
struct StandupTabPicker: View {
    @Binding var tab: String
    let isZoomDay: Bool

    var body: some View {
        Picker("View", selection: $tab) {
            Text("Me").tag("me")
            Text("Meeting").tag("meeting")
            Text("Blockers").tag("blockers")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help(isZoomDay ? "Today's standup is on Zoom" : "The standup isn't on Zoom today")
    }
}

/// A titled column for the wide and large layouts.
struct StandupColumn<Content: View>: View {
    let title: String
    let systemImage: String
    let note: String?
    let content: Content

    init(_ title: String, systemImage: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage).font(.subheadline.bold())
                Spacer(minLength: 4)
                if let note { Text(note).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Narrow: is my update ready, where's the standup at, how many blockers, and the one button.
struct StandupGlance: View {
    let state: StandupState
    let commands: StandupCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusDot(state.update == nil ? .warning : .success)
                    Text(state.update == nil ? state.unpreparedTitle : "Update ready").font(.headline).lineLimit(1)
                }
                if let update = state.update {
                    Text("\(update.yesterday.count) done · \(update.today.count) next" + (state.preparedAt.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.live != nil {
                HStack(spacing: 6) {
                    StatusDot(.danger)
                    Text(state.live?["speaking_now"]?.string.map { "Live · \($0) speaking" } ?? "Standup live").font(.callout).lineLimit(1)
                }
                if state.upSoon { Label("You're up soon", systemImage: "hand.raised").font(.callout.bold()).foregroundStyle(.orange) }
            } else if let report = state.report {
                Label("Report ready · \(report.actionItems.count) action item\(report.actionItems.count == 1 ? "" : "s")", systemImage: "doc.text")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Label(state.isZoomDay ? "Standup at \(state.time)" : "Not on Zoom today", systemImage: "video").font(.callout).foregroundStyle(.secondary)
            }
            Label(state.blockers.isEmpty ? "No open blockers" : "\(state.blockers.count) open blocker\(state.blockers.count == 1 ? "" : "s")",
                  systemImage: state.blockers.isEmpty ? "checkmark.seal" : "exclamationmark.octagon")
                .font(.callout)
                .foregroundStyle(state.staleBlockers > 0 ? .red : state.blockers.isEmpty ? .secondary : .primary)
            Spacer(minLength: 0)
            if state.isPreparing {
                ProgressView("Preparing…").controlSize(.small)
            } else if let update = state.update {
                CopyUpdateButton(update: update).buttonStyle(.bordered).controlSize(.small)
            } else if let prepare = commands.prepare {
                Button("Prepare Now", systemImage: "sparkles", action: prepare).buttonStyle(.borderedProminent).controlSize(.small)
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Large: the day in numbers.
struct StandupSummary: View {
    let state: StandupState

    var body: some View {
        HStack(spacing: 16) {
            stat(state.update.map { "\($0.yesterday.count)" } ?? "–", "Done since last", tone: .neutral)
            stat(state.update.map { "\($0.today.count)" } ?? "–", "Next", tone: .neutral)
            stat("\(state.blockers.count)", "Open blockers", tone: state.staleBlockers > 0 ? .danger : state.blockers.isEmpty ? .neutral : .warning)
            stat(state.time, state.live != nil ? "Live now" : state.report != nil ? "Reported" : state.isZoomDay ? "On Zoom" : "Not on Zoom",
                 tone: state.live != nil ? .danger : .neutral)
        }
    }

    private func stat(_ value: String, _ label: String, tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tone == .neutral ? Color.primary : tone.color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension StandupState {
    /// The gallery's sample day: a prepared update, the standup's report, two blockers.
    static var sample: StandupState {
        StandupState(
            update: StandupUpdate(
                yesterday: [StandupItem(text: "Finished the renewal endpoint and its tests", ticket: "LAF-5680", refs: ["a1b2c3d", "api#88"]),
                            StandupItem(text: "Reviewed Sam's checkout PR", ticket: "WEB-412", refs: ["web#412"])],
                today: [StandupItem(text: "Fix the flaky renewal test Dashii flagged", ticket: "LAF-5680", refs: ["api#88"], kind: "fix"),
                        StandupItem(text: "Waiting for review on the renewal PR", ticket: "LAF-5680", refs: ["api#88"], kind: "waiting"),
                        StandupItem(text: "Proration on upgrade", ticket: "LAF-5702", refs: [], kind: "start")],
                blockers: [StandupItem(text: "QA workspace crash-loops (OOM)", ticket: "LAF-5680", refs: ["laf-5680"])]),
            preparedAt: .now.addingTimeInterval(-20 * 60),
            myName: "Sadik",
            report: MeetingReport(
                summary: "Renewals land this week; QA is blocked on the workspace OOM.",
                people: [
                    .init(name: "Sadik", yesterday: ["Renewal endpoint and tests"], today: ["Fix the flaky renewal test"], blockers: ["QA workspace OOM"], words: 84),
                    .init(name: "Ada", yesterday: ["Checkout copy changes"], today: ["Review the renewal PR"], blockers: [], words: 61),
                    .init(name: "Sam", yesterday: ["Proration spike"], today: ["Pair on upgrade proration"], blockers: [], words: 47),
                ],
                blockers: [.init(owner: "Sadik", task: "QA workspace OOM")],
                actionItems: [.init(owner: "Ada", task: "Review api#88 today"), .init(owner: "Sam", task: "Raise the QA workspace memory limit")],
                notHeard: ["Linus"], namesFromCaptions: true),
            blockers: [
                StandupBlockerRow(id: UUID(), text: "QA workspace crash-loops (OOM)", owner: "Sadik", reference: "LAF-5680", daysOpen: 1),
                StandupBlockerRow(id: UUID(), text: "Waiting on the payments sandbox keys", owner: "Sam", reference: "", daysOpen: 4),
            ])
    }
}
