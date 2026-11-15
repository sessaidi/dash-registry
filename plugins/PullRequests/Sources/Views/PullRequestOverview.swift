import DashKit
import DashKitUI
import SwiftUI

/// The numbers at the top of the Overview tab, from GitHub's pull request and its check runs.
struct PRStats: Equatable {
    var files = 0
    var additions = 0
    var deletions = 0
    var commits = 0
    var comments = 0
    /// "clean", "blocked", "dirty" (conflicts), "behind", "unstable", …
    var mergeState = ""
    var checksPassed = 0
    var checksFailed = 0
    var checksPending = 0

    init() {}

    init(pull: JSONValue, checkRuns: [JSONValue]) {
        files = pull["changed_files"]?.int ?? 0
        additions = pull["additions"]?.int ?? 0
        deletions = pull["deletions"]?.int ?? 0
        commits = pull["commits"]?.int ?? 0
        comments = (pull["comments"]?.int ?? 0) + (pull["review_comments"]?.int ?? 0)
        mergeState = pull["mergeable_state"]?.string ?? ""
        for run in checkRuns {
            switch run["status"]?.string == "completed" ? run["conclusion"]?.string ?? "" : "pending" {
            case "success", "neutral", "skipped": checksPassed += 1
            case "pending": checksPending += 1
            default: checksFailed += 1
            }
        }
    }

    var checksTone: Tone { checksFailed > 0 ? .danger : checksPending > 0 ? .warning : checksPassed > 0 ? .success : .neutral }

    var mergeLabel: (text: String, tone: Tone) {
        switch mergeState {
        case "clean": ("Ready", .success)
        case "dirty": ("Conflicts", .danger)
        case "blocked": ("Blocked", .warning)
        case "behind": ("Behind base", .warning)
        case "unstable": ("Checks failing", .danger)
        case "draft": ("Draft", .neutral)
        default: ("Unknown", .neutral)
        }
    }
}

/// A coloured tile: an icon, a big value and what it counts.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    let systemImage: String
    var tone: Tone = .info

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption.weight(.medium)).foregroundStyle(tone.color)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tone.color.opacity(0.25), lineWidth: 1))
    }
}

/// The tiles row.
struct PRStatTiles: View {
    let stats: PRStats?
    let pr: PullRequest

    var body: some View {
        let stats = stats ?? PRStats()
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            StatTile(title: "Files", value: "\(stats.files)", systemImage: "doc.on.doc", tone: .info)
            StatTile(title: "Lines", value: "+\(stats.additions) −\(stats.deletions)",
                     detail: stats.additions + stats.deletions > 0 ? "\(Int(Double(stats.additions) / Double(stats.additions + stats.deletions) * 100))% added" : nil,
                     systemImage: "plus.forwardslash.minus", tone: .accent)
            StatTile(title: "Commits", value: "\(stats.commits)", systemImage: "point.3.connected.trianglepath.dotted", tone: .neutral)
            StatTile(title: "Checks", value: stats.checksPassed + stats.checksFailed + stats.checksPending == 0 ? "—" : "\(stats.checksPassed)/\(stats.checksPassed + stats.checksFailed + stats.checksPending)",
                     detail: stats.checksFailed > 0 ? "\(stats.checksFailed) failing" : stats.checksPending > 0 ? "\(stats.checksPending) running" : nil,
                     systemImage: "checkmark.circle", tone: stats.checksTone)
            StatTile(title: "Reviews", value: "\(pr.approvals) ✓", detail: pr.changesRequested > 0 ? "\(pr.changesRequested) want changes" : nil,
                     systemImage: "person.2", tone: pr.changesRequested > 0 ? .danger : pr.approvals > 0 ? .success : .neutral)
            StatTile(title: "Merge", value: stats.mergeLabel.text, detail: stats.comments > 0 ? "\(stats.comments) comments" : nil,
                     systemImage: "arrow.triangle.merge", tone: stats.mergeLabel.tone)
        }
        .redacted(reason: self.stats == nil ? .placeholder : [])
    }
}
