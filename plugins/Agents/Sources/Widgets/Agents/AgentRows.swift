import DashKit
import DashKitUI
import SwiftUI

/// Narrow: the headline and the sessions to look at first.
struct AgentGlance: View {
    let rows: [AgentSummary]
    let selectedID: UUID?
    let open: (UUID) -> Void
    /// The height there is, to show as many rows as fit.
    let room: CGFloat

    var body: some View {
        let ordered = AgentSummary.byAttention(rows)
        let fit = max(1, Int((room - 44) / 26))
        VStack(alignment: .leading, spacing: 8) {
            AgentHeadline(rows: rows)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ordered.prefix(fit)) { row in
                    Button { open(row.id) } label: {
                        HStack(spacing: 6) {
                            StatusDot(row.tone, help: row.stateLabel)
                            Text(row.issueKey).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(row.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .background(selectedID == row.id ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            if ordered.count > fit {
                Text("\(ordered.count - fit) more").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "2 working · 1 needs you", with the dot of what matters most.
struct AgentHeadline: View {
    let rows: [AgentSummary]

    private var tone: Tone {
        if rows.contains(where: { $0.status == "failed" && !$0.hasPullRequest }) { return .danger }
        if rows.contains(where: \.needsYou) { return .warning }
        return rows.contains(where: \.isWorking) ? .info : .success
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone)
            Text(AgentSummary.headline(rows)).font(.headline).lineLimit(1)
        }
    }
}

/// Medium: every session as a row, with its state.
struct AgentRows: View {
    let rows: [AgentSummary]
    var selectedID: UUID? = nil
    let open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                AgentHeadline(rows: rows)
                Spacer()
                Text(AgentCost.total(rows)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("Spent by these agents")
            }
            List(rows) { row in
                AgentRow(row: row)
                    .onTapGesture { open(row.id) }
                    .listRowBackground(selectedID == row.id ? Color.accentColor.opacity(0.18) : Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One session: dot, ticket and title, phase · branch · cost, and its state when it isn't plain work.
struct AgentRow: View {
    let row: AgentSummary

    var body: some View {
        ItemRow("\(row.issueKey) · \(row.title)", subtitle: "\(row.phase) · \(row.branch) · \(AgentCost.format(row.costUSD))") {
            StatusDot(row.tone, help: row.stateLabel)
        } trailing: {
            if row.hasPullRequest {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(.green).help("PR open")
            } else if !row.isWorking {
                Badge(row.stateLabel, tone: row.tone)
            }
        }
    }
}

/// Wide: a table with a column per fact.
struct AgentTable: View {
    let rows: [AgentSummary]
    let selectedID: UUID?
    let open: (UUID) -> Void

    var body: some View {
        // Choosing a row opens it; choosing nothing unselects the selected one.
        let selection = Binding<UUID?>(get: { selectedID }, set: { id in
            if let id { open(id) } else if let selectedID { open(selectedID) }
        })
        Table(rows, selection: selection) {
            TableColumn("") { (row: AgentSummary) in StatusDot(row.tone, help: row.stateLabel) }.width(12)
            TableColumn("Ticket") { (row: AgentSummary) in Text(row.issueKey).monospaced() }.width(min: 64, ideal: 80, max: 110)
            TableColumn("Title") { (row: AgentSummary) in Text(row.title).lineLimit(1).help(row.title) }.width(min: 140, ideal: 280)
            TableColumn("State") { (row: AgentSummary) in Badge(row.stateLabel, tone: row.tone) }.width(min: 70, ideal: 84, max: 100)
            TableColumn("Phase") { (row: AgentSummary) in Text(row.phase.capitalized).foregroundStyle(.secondary) }.width(min: 70, ideal: 84, max: 100)
            TableColumn("Cost") { (row: AgentSummary) in Text(AgentCost.format(row.costUSD)).monospacedDigit() }.width(min: 44, ideal: 54, max: 70)
            TableColumn("Updated") { (row: AgentSummary) in RelativeTime(row.updatedAt).foregroundStyle(.secondary) }.width(min: 56, ideal: 72, max: 96)
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// Large: totals on top, the sessions on the left, the focused one's detail on the right.
struct AgentOverview: View {
    let rows: [AgentSummary]
    let selectedID: UUID?
    let open: (UUID) -> Void
    let openChat: (UUID) -> Void

    /// The selected session, else the one that needs a look first.
    private var focused: AgentSummary? { rows.first { $0.id == selectedID } ?? AgentSummary.byAttention(rows).first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                AgentStat(value: "\(rows.count(where: \.isWorking))", label: "Working", tone: rows.contains(where: \.isWorking) ? .info : .neutral)
                AgentStat(value: "\(rows.count(where: \.needsYou))", label: "Need you", tone: rows.contains(where: \.needsYou) ? .warning : .neutral)
                AgentStat(value: "\(rows.count(where: \.isDone))", label: "PRs open", tone: rows.contains(where: \.isDone) ? .success : .neutral)
                AgentStat(value: AgentCost.total(rows), label: "Spent", tone: .neutral)
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                List(AgentSummary.byAttention(rows)) { row in
                    AgentRow(row: row)
                        .onTapGesture { open(row.id) }
                        .listRowBackground(focused?.id == row.id ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity)
                if let focused {
                    Divider()
                    AgentDetail(row: focused, openChat: openChat)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// A number with its caption, for the summary strip.
struct AgentStat: View {
    let value: String
    let label: String
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tone == .neutral ? Color.primary : tone.color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The focused session: what it is, where it is, what went wrong, and Open.
struct AgentDetail: View {
    let row: AgentSummary
    let openChat: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(row.issueKey).font(.callout.monospaced()).foregroundStyle(.secondary)
                Badge(row.stateLabel, tone: row.tone)
            }
            Text(row.title).font(.headline).lineLimit(3)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Phase").foregroundStyle(.secondary)
                    Text(row.phase.capitalized)
                }
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text(row.branch).monospaced().lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("Cost").foregroundStyle(.secondary)
                    Text(AgentCost.format(row.costUSD)).monospacedDigit()
                }
                GridRow {
                    Text("Updated").foregroundStyle(.secondary)
                    RelativeTime(row.updatedAt)
                }
            }
            .font(.callout)
            if let error = row.lastError, row.status == "failed" {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            Spacer(minLength: 0)
            Button(row.needsYou ? "Open and Reply" : "Open Chat") { openChat(row.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Open the agent's chat")
        }
    }
}

enum AgentCost {
    static func format(_ usd: Double) -> String { usd.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
    static func total(_ rows: [AgentSummary]) -> String { format(rows.reduce(0) { $0 + $1.costUSD }) }
}

/// Running, failed or done (the chat window's header).
struct AgentStatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(status == "running" ? Color.blue : status == "failed" ? .red : .green)
            .frame(width: 8, height: 8)
            .help(status)
    }
}
