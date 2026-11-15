import DashKit
import DashKitUI
import SwiftUI

/// The widget's PRs drawn for its size family: a glance when narrow, the list in a usual card,
/// a grouped table when wide, and the table with a summary and a detail panel when large.
/// Fed plain values, so the live widget and the gallery preview draw the same thing.
struct PullRequestsContent: View {
    let pulls: [PullRequest]
    /// Latest review per PR uid.
    let reviews: [String: PRReview]
    var selectedUID: String? = nil
    /// nil: rows don't open (previews).
    let onSelect: ((PullRequest) -> Void)?
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        switch layout.family {
        case .narrow:
            PullRequestGlance(pulls: pulls, reviews: reviews, selectedUID: selectedUID, onSelect: onSelect)
        case .wide:
            PullRequestTable(pulls: pulls, reviews: reviews, selectedUID: selectedUID, onSelect: onSelect)
        case .large:
            PullRequestOverview(pulls: pulls, reviews: reviews, selectedUID: selectedUID, onSelect: onSelect)
        default:
            PullRequestRows(pulls: pulls, reviews: reviews, selectedUID: selectedUID, onSelect: onSelect)
        }
    }
}

/// Who a PR is waiting on, from the user's point of view: the table's groups.
enum PullRequestGroup: String, CaseIterable, Identifiable {
    case review = "Needs my review"
    case mine = "Mine"
    case others = "Others"

    var id: String { rawValue }

    static func of(_ pr: PullRequest) -> Self { pr.reviewRequested ? .review : pr.isMine ? .mine : .others }

    /// PRs ordered by group (needs my review first), keeping their order inside a group.
    static func ordered(_ pulls: [PullRequest]) -> [PullRequest] {
        allCases.flatMap { group in pulls.filter { of($0) == group } }
    }
}

extension PRReview {
    var verdictLabel: String {
        switch verdict {
        case "approve": "Approve"
        case "request_changes": "Changes"
        case "comment": "Comment"
        default: verdict.replacing("_", with: " ").capitalized
        }
    }

    var verdictTone: Tone {
        switch verdict {
        case "approve": .success
        case "request_changes": .danger
        default: .info
        }
    }

    var riskTone: Tone {
        switch risk {
        case "high": .danger
        case "medium": .warning
        default: .success
        }
    }
}

/// Dashii's verdict and risk as badges, or where the review stands.
struct ReviewVerdictBadges: View {
    let review: PRReview?

    var body: some View {
        HStack(spacing: 4) {
            switch review?.status {
            case "done":
                if let review {
                    Badge(review.verdictLabel, tone: review.verdictTone)
                    if !review.risk.isEmpty { Badge("\(review.risk) risk", tone: review.riskTone) }
                }
            case "running", "queued":
                ProgressView().controlSize(.mini)
                Text("Reviewing").font(.caption).foregroundStyle(.secondary)
            case "failed":
                Badge("Failed", tone: .danger, systemImage: "exclamationmark.triangle")
            default:
                Text("Not reviewed").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Human reviews on the PR: approvals and requested changes.
struct HumanFeedback: View {
    let pr: PullRequest

    var body: some View {
        HStack(spacing: 6) {
            if pr.approvals > 0 {
                Label("\(pr.approvals)", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.color)
            }
            if pr.changesRequested > 0 {
                Label("\(pr.changesRequested)", systemImage: "xmark.circle.fill").foregroundStyle(Tone.danger.color)
            }
            if pr.approvals == 0 && pr.changesRequested == 0 {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .help(pr.feedbackFrom.isEmpty ? "Human reviews" : "Latest review from \(pr.feedbackFrom)")
    }
}

// MARK: - Narrow

/// Narrow: how many PRs wait on the user, then the top few, most urgent first.
private struct PullRequestGlance: View {
    let pulls: [PullRequest]
    let reviews: [String: PRReview]
    let selectedUID: String?
    let onSelect: ((PullRequest) -> Void)?
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        let waiting = pulls.filter(\.reviewRequested).count
        // Three rows when they fit; fewer in a short card.
        let room = max(1, min(3, Int((layout.size.height - 44) / 40)))
        let top = PullRequestGroup.ordered(pulls).prefix(room)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(waiting)")
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(waiting > 0 ? Tone.warning.color : Color.secondary)
                Text(waiting == 1 ? "needs your review" : "need your review")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(spacing: 2) {
                ForEach(Array(top)) { pr in
                    ItemRow(pr.title, subtitle: "\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)#\(pr.number) · \(pr.author)") {
                        ReviewBadge(review: reviews[pr.uid])
                    }
                    .lineLimit(1)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(selectedUID == pr.uid ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                    .onTapGesture { onSelect?(pr) }
                }
            }
            if pulls.count > top.count {
                Text("+\(pulls.count - top.count) more open").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

/// Medium: the list, one PR per row with its verdict and what it needs from the user.
struct PullRequestRows: View {
    let pulls: [PullRequest]
    /// Latest review per PR uid.
    let reviews: [String: PRReview]
    var selectedUID: String? = nil
    /// nil: rows don't open (previews).
    let onSelect: ((PullRequest) -> Void)?

    var body: some View {
        List(pulls) { pr in
            PullRequestRow(pr: pr, review: reviews[pr.uid])
                .onTapGesture { onSelect?(pr) }
                .listRowBackground(selectedUID == pr.uid ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct PullRequestRow: View {
    let pr: PullRequest
    let review: PRReview?

    var body: some View {
        ItemRow(pr.title, subtitle: "\(pr.repo)#\(pr.number) · \(pr.author) · \(pr.updatedAt.relative)") {
            ReviewBadge(review: review)
        } trailing: {
            HStack(spacing: 4) {
                if pr.isDraft { Badge("Draft") }
                if pr.reviewRequested {
                    Badge("Review", tone: .warning, systemImage: "eye").help("Your review is requested")
                } else if review?.status == "done", let review, !review.risk.isEmpty {
                    Badge(review.risk, tone: review.riskTone).help("Dashii's risk estimate")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Wide

/// Wide: a table grouped by who the PR waits on, with the verdict, human reviews and age as columns.
struct PullRequestTable: View {
    let pulls: [PullRequest]
    let reviews: [String: PRReview]
    var selectedUID: String?
    let onSelect: ((PullRequest) -> Void)?

    struct Row: Identifiable {
        let pr: PullRequest
        let review: PRReview?
        var id: String { pr.uid }
    }

    struct Group: Identifiable {
        let group: PullRequestGroup
        let rows: [Row]
        var id: String { group.id }
    }

    private var groups: [Group] {
        PullRequestGroup.allCases.compactMap { group in
            let rows = pulls.filter { PullRequestGroup.of($0) == group }.map { Row(pr: $0, review: reviews[$0.uid]) }
            return rows.isEmpty ? nil : Group(group: group, rows: rows)
        }
    }

    /// Picking a row selects it (and opens it); unselecting the row unselects the PR.
    private var selection: Binding<String?> {
        Binding {
            selectedUID
        } set: { uid in
            if let uid, let pr = pulls.first(where: { $0.uid == uid }) {
                onSelect?(pr)
            } else if uid == nil, let current = pulls.first(where: { $0.uid == selectedUID }) {
                onSelect?(current)
            }
        }
    }

    var body: some View {
        Table(of: Row.self, selection: selection) {
            TableColumn("Repository") { row in
                Text("\(row.pr.repo)#\(String(row.pr.number))").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Title") { row in
                HStack(spacing: 4) {
                    if row.pr.isDraft { Badge("Draft") }
                    Text(row.pr.title).lineLimit(1).help(row.pr.title)
                }
            }
            .width(min: 140, ideal: 280)
            TableColumn("Author") { row in
                Text(row.pr.author).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 50, ideal: 80)
            TableColumn("Dashii") { row in ReviewVerdictBadges(review: row.review) }
                .width(min: 90, ideal: 140)
            TableColumn("Reviews") { row in HumanFeedback(pr: row.pr) }
                .width(min: 44, ideal: 60)
            TableColumn("Age") { row in
                Text(row.pr.createdAt.relative).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 56)
        } rows: {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { TableRow($0) }
                } header: {
                    Text("\(group.group.rawValue) · \(group.rows.count)")
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Large

/// Large: a summary strip, the grouped table, and the selected PR's detail (or the first one
/// waiting on the user).
private struct PullRequestOverview: View {
    let pulls: [PullRequest]
    let reviews: [String: PRReview]
    let selectedUID: String?
    let onSelect: ((PullRequest) -> Void)?
    @Environment(\.widgetLayout) private var layout

    private var focus: PullRequest? {
        pulls.first { $0.uid == selectedUID } ?? PullRequestGroup.ordered(pulls).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            HStack(alignment: .top, spacing: 12) {
                PullRequestTable(pulls: pulls, reviews: reviews, selectedUID: selectedUID, onSelect: onSelect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let focus {
                    PullRequestDetailPanel(pr: focus, review: reviews[focus.uid])
                        .frame(width: layout.size.width * 0.36)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var summary: some View {
        let done = pulls.compactMap { reviews[$0.uid] }.filter { $0.status == "done" }
        let tiles: [(String, String, Tone)] = [
            ("\(pulls.filter(\.reviewRequested).count)", "Need your review", .warning),
            ("\(pulls.filter(\.isMine).count)", "Yours open", .info),
            ("\(done.filter { $0.risk == "high" }.count)", "High risk", .danger),
            ("\(pulls.filter { $0.isMine && $0.changesRequested > 0 }.count)", "Changes asked on yours", .accent),
        ]
        return HStack(spacing: 8) {
            ForEach(tiles, id: \.1) { value, label, tone in
                MetricView(value, label: label, tone: value == "0" ? .neutral : tone)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
            }
        }
    }
}

/// One PR at a glance: who, where, Dashii's review and the description.
private struct PullRequestDetailPanel: View {
    let pr: PullRequest
    let review: PRReview?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("\(pr.repo)#\(pr.number) · \(pr.author) · \(pr.headRef) → \(pr.baseRef)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 4) {
                    if pr.isDraft { Badge("Draft") }
                    if pr.reviewRequested { Badge("Your review", tone: .warning, systemImage: "eye") }
                    if pr.approvals > 0 { Badge("\(pr.approvals) approved", tone: .success, systemImage: "checkmark") }
                    if pr.changesRequested > 0 { Badge("\(pr.changesRequested) changes asked", tone: .danger, systemImage: "xmark") }
                }
                Divider()
                HStack {
                    ReviewBadge(review: review)
                    Text("Dashii review").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    ReviewVerdictBadges(review: review)
                }
                if let review, review.status == "done" {
                    if !review.summary.isEmpty { Text(review.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    ForEach(review.findings, id: \.self) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Badge(finding.severity, tone: ["blocker", "major"].contains(finding.severity) ? .danger : .warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.title).font(.callout)
                                Text(finding.line > 0 ? "\(finding.file):\(finding.line)" : finding.file)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    if !review.testing.isEmpty {
                        Text("Testing: \(review.testing)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !pr.body.isEmpty {
                    Divider()
                    Text("Description").font(.subheadline.weight(.semibold))
                    InlineMarkdown(pr.body).font(.callout).lineLimit(8)
                }
                if let url = URL(string: pr.url), !pr.url.isEmpty {
                    Link("Open on GitHub", destination: url).font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}
