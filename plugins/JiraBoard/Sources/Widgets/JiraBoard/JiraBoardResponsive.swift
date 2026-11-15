import DashKit
import DashKitUI
import SwiftUI

/// The board drawn for its size family: the user's work in progress when narrow, a list by status
/// in a usual card, lanes side by side when wide, and lanes with a summary and the selected
/// ticket's detail when large. Fed plain values, so the widget and the gallery preview draw the
/// same thing; the selection comes from `jiraSelectedKey`.
struct JiraBoardContent: View {
    let config: JiraBoardWidget.Config
    let tickets: [JiraTicket]
    /// The board's columns, or one per status for followed tickets.
    let columns: [JiraClient.Column]
    /// nil in previews: tickets aren't tappable.
    let onSelect: ((JiraTicket) -> Void)?
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        switch layout.family {
        case .narrow:
            JiraGlance(tickets: tickets, onSelect: onSelect)
        case .wide:
            JiraBoardLayout(config: config, tickets: tickets, columns: columns, onSelect: onSelect)
        case .large:
            JiraOverview(config: config, tickets: tickets, columns: columns, onSelect: onSelect)
        default:
            JiraStatusList(tickets: tickets, columns: columns, onSelect: onSelect)
        }
    }

    /// Jira's status category as a tone: not started, in progress, finished.
    static func tone(_ category: String) -> Tone {
        switch category {
        case "done": .success
        case "indeterminate": .info
        default: .neutral
        }
    }

    /// The user's own work in progress (followed = assigned to or watched by them); every
    /// ticket in progress when they follow none of the shown ones.
    static func inProgress(_ tickets: [JiraTicket]) -> (tickets: [JiraTicket], mine: Bool) {
        let started = tickets.filter { $0.statusCategory == "indeterminate" }
        let mine = started.filter(\.followed)
        return mine.isEmpty ? (started, false) : (mine, true)
    }
}

// MARK: - Narrow

/// Narrow: how many tickets the user has in progress, and the top few; no lanes.
private struct JiraGlance: View {
    let tickets: [JiraTicket]
    let onSelect: ((JiraTicket) -> Void)?
    @Environment(\.widgetLayout) private var layout
    @Environment(\.jiraSelectedKey) private var selectedKey

    var body: some View {
        let progress = JiraBoardContent.inProgress(tickets)
        // In progress first, then what's next (to do), then the rest.
        let rest = tickets.filter { ticket in !progress.tickets.contains { $0.key == ticket.key } }
        let ordered = progress.tickets + rest.filter { $0.statusCategory == "new" } + rest.filter { $0.statusCategory != "new" }
        let room = max(1, min(3, Int((layout.size.height - 44) / 40)))
        let top = ordered.prefix(room)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(progress.tickets.count)")
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(progress.tickets.isEmpty ? Color.secondary : Tone.info.color)
                Text("in progress")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(spacing: 2) {
                ForEach(Array(top)) { ticket in
                    ItemRow(ticket.summary, subtitle: "\(ticket.key) · \(ticket.statusName)") {
                        StatusDot(JiraBoardContent.tone(ticket.statusCategory), help: ticket.statusName)
                    }
                    .lineLimit(1)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(selectedKey == ticket.key ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                    .onTapGesture { onSelect?(ticket) }
                }
            }
            if tickets.count > top.count {
                Text("+\(tickets.count - top.count) more").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

/// Medium: one list, a section per column (or status), so it reads top to bottom.
private struct JiraStatusList: View {
    let tickets: [JiraTicket]
    let columns: [JiraClient.Column]
    let onSelect: ((JiraTicket) -> Void)?
    @Environment(\.jiraSelectedKey) private var selectedKey

    private struct Group: Identifiable {
        let name: String
        let color: Color
        let tickets: [JiraTicket]
        var id: String { name }
    }

    private var groups: [Group] {
        let lanes = columns.isEmpty ? JiraBoardLayout.statusColumns(tickets) : columns
        return lanes.enumerated().compactMap { index, column in
            let cards = tickets.filter { column.statusIDs.contains($0.statusID) }
            return cards.isEmpty ? nil : Group(name: column.name, color: JiraBoardLayout.color(index, of: lanes.count), tickets: cards)
        }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.tickets) { ticket in
                        ItemRow(ticket.summary, subtitle: "\(ticket.key) · \(ticket.assignee ?? "Unassigned")") {
                            Circle().fill(group.color).frame(width: 8, height: 8)
                        }
                        .onTapGesture { onSelect?(ticket) }
                        .listRowBackground(selectedKey == ticket.key ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.name)
                        Text("\(group.tickets.count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Large

/// Large: a summary strip, the lanes, and the selected ticket (or the user's first in progress).
private struct JiraOverview: View {
    let config: JiraBoardWidget.Config
    let tickets: [JiraTicket]
    let columns: [JiraClient.Column]
    let onSelect: ((JiraTicket) -> Void)?
    @Environment(\.widgetLayout) private var layout
    @Environment(\.jiraSelectedKey) private var selectedKey

    private var focus: JiraTicket? {
        tickets.first { $0.key == selectedKey } ?? JiraBoardContent.inProgress(tickets).tickets.first ?? tickets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            HStack(alignment: .top, spacing: 12) {
                JiraBoardLayout(config: config, tickets: tickets, columns: columns, onSelect: onSelect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let focus {
                    JiraTicketPanel(ticket: focus)
                        .frame(width: layout.size.width * 0.3)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var summary: some View {
        // Every ticket shown is followed, so the fourth tile is what nobody has picked up.
        let tiles: [(String, String, Tone)] = [
            ("\(tickets.filter { $0.statusCategory == "new" }.count)", "To do", .neutral),
            ("\(tickets.filter { $0.statusCategory == "indeterminate" }.count)", "In progress", .info),
            ("\(tickets.filter { $0.statusCategory == "done" }.count)", "Done", .success),
            ("\(tickets.filter { $0.assignee == nil && $0.statusCategory != "done" }.count)", "Unassigned", .warning),
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

/// One ticket at a glance: what it is, where it stands, who has it.
private struct JiraTicketPanel: View {
    let ticket: JiraTicket

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(ticket.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let type = ticket.issueType { Text("· \(type)").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                Text(ticket.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    StatusPill(name: ticket.statusName, category: ticket.statusCategory)
                    if let priority = ticket.priority {
                        Badge(priority, tone: ["Highest", "High"].contains(priority) ? .danger : priority == "Medium" ? .warning : .neutral,
                              systemImage: "flag")
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Assignee").foregroundStyle(.secondary)
                        Text(ticket.assignee ?? "Unassigned")
                    }
                    if let updated = ticket.updated {
                        GridRow {
                            Text("Updated").foregroundStyle(.secondary)
                            RelativeTime(updated)
                        }
                    }
                    if !ticket.labels.isEmpty {
                        GridRow {
                            Text("Labels").foregroundStyle(.secondary)
                            Text(ticket.labels.joined(separator: ", ")).lineLimit(2)
                        }
                    }
                }
                .font(.callout)
                if let url = URL(string: ticket.url), !ticket.url.isEmpty {
                    Link("Open in Jira", destination: url).font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}
