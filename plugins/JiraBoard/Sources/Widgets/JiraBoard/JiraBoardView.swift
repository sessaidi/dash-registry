import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The live widget: issues from the store (`@Query`), so syncs show as they land; handles Dashii's
/// actions and publishes the selection for linked widgets.
struct JiraBoardView: View {
    @Binding var config: JiraBoardWidget.Config
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after the mode and Dashii's narrowing.
    let query: WidgetQuery?
    let queryText: String
    @State private var queryKeys: [String]?
    @Query(sort: \JiraIssue.updated, order: .reverse) private var issues: [JiraIssue]
    /// The issue whose detail sheet is open.
    @State private var opened: JiraTicket?
    /// The issue the user picked: highlighted, and published for linked widgets until another is
    /// picked or it's clicked again.
    @State private var selectedKey: String?
    /// What Dashii's actions changed for now (mode, board, hide done). Not saved: it resets when
    /// the widget's settings change; the settings keep their values.
    @State private var override: JiraBoardWidget.Config?
    /// What Dashii narrowed the board to (not saved): text, and a column or status.
    @State private var search = ""
    @State private var status = ""
    @State private var following = false

    private var jira: JiraBoardFeature? { host.ext(JiraBoardFeature.self) }

    /// The settings with Dashii's temporary changes on top.
    private var effective: JiraBoardWidget.Config { override ?? config }

    /// No board chosen: the first followed board.
    private var resolvedConfig: JiraBoardWidget.Config {
        var config = effective
        if config.board == nil { config.board = jira?.boards.first?.id }
        return config
    }

    /// What the board shows: the mode and Dashii's narrowing, then the DashQL query.
    private var visible: [JiraTicket] { QueryRows.ordered(narrowed, by: queryKeys) }

    private func row(_ ticket: JiraTicket) -> JSONValue {
        issues.first { $0.key == ticket.key }?.queryRow ?? ["key": .string(ticket.key), "summary": .string(ticket.summary)]
    }

    private var narrowed: [JiraTicket] {
        let config = resolvedConfig
        return JiraBoardActions.filter(JiraTicket.visible(issues.map(JiraTicket.init), config: config), search: search, status: status,
                                       columns: jira?.columns(board: config.board) ?? [])
    }

    var body: some View {
        board
            // Follow a ticket from here: key, link or a few words.
            .overlay(alignment: .topTrailing) {
                if let jira, (try? jira.client) != nil {
                    HStack(spacing: 8) {
                        QueryCount(shown: visible.count, total: narrowed.count, query: queryText)
                        // The user's own switch is saved (and drops Dashii's temporary mode).
                        Picker("Show", selection: Binding(get: { effective.mode }, set: { config.mode = $0; override = nil })) {
                            Text("Board").tag("board")
                            Text("Following \(issues.filter { $0.followed && !(effective.hideDone && $0.statusCategory == "done") }.count)").tag("followed")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Button("Follow a Ticket", systemImage: "plus") { following = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Follow a ticket: paste its key or link, or search")
                            .popover(isPresented: $following, arrowEdge: .bottom) { FollowTicketPopover(jira: jira) }
                    }
                    .offset(y: -34)
                }
            }
            .handlesWidgetActions { name, input in
                if name == "clear_selection" {
                    selectedKey = nil
                    return "cleared"
                }
                let columns = jira?.columns(board: resolvedConfig.board) ?? []
                // Actions change what's shown for now, never the saved settings.
                var view = effective
                let outcome = try JiraBoardActions.perform(name, input, config: &view, search: &search, status: &status,
                                                           tickets: visible, boards: (jira?.boards ?? []).map { ($0.id, $0.name) }, columns: columns)
                // `clear` also drops Dashii's temporary mode, board and hide-done.
                override = name == "clear" || view == config ? nil : view
                if let ticket = outcome.select {
                    selectedKey = ticket.key
                    opened = ticket
                }
                return outcome.reply
            }
            .onChange(of: config) { override = nil }
            .onExitCommand { selectedKey = nil }
            .reportsSelection(selectedKey.flatMap { key in issues.first { $0.key == key }?.queryRow })
            .reportsWidgetState(state)
            .task(id: QueryRows.key(queryText, narrowed, row: row)) {
                queryKeys = await QueryRows.ids(query, narrowed, row: row)
            }
    }

    private var state: JSONValue {
        let config = resolvedConfig
        let visible = visible
        return [
            "mode": .string(config.mode), "hide_done": .bool(config.hideDone),
            "board": jira?.boards.first { $0.id == config.board }.map { .string($0.name) } ?? .null,
            "search": search.isEmpty ? .null : .string(search), "status": status.isEmpty ? .null : .string(status),
            "shown": .array(visible.prefix(40).map { .string("\($0.key) [\($0.statusName)] \($0.summary)") }),
            "open_issue": opened.map { .string($0.key) } ?? .null,
            "selected": selectedKey.map(JSONValue.string) ?? .null,
            "temporary_changes": .bool(override != nil),
        ]
    }

    private var board: some View {
        let config = resolvedConfig
        let visible = visible
        return Group {
            if let jira, (try? jira.client) == nil {
                setupPrompt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if config.mode == "followed", visible.isEmpty, jira?.isSyncing != true {
                // Following nothing yet (or nothing left after hiding done): say so and offer to follow.
                ContentUnavailableView {
                    Label(jira?.followedKeys.isEmpty == false ? "Nothing to show" : "You don't follow any ticket", systemImage: "star")
                } description: {
                    Text(jira?.followedKeys.isEmpty == false
                         ? "The tickets you follow are done or hidden. Turn off “Hide done” to see them."
                         : "Follow tickets to see them here, in columns by status. Nothing changes in Jira.")
                } actions: {
                    Button("Follow a Ticket…", systemImage: "plus") { following = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label(jira?.isSyncing == true ? "Syncing…" : "No issues", systemImage: "checklist")
                } description: {
                    Text(jira?.lastError ?? (config.mode == "board" && jira?.boardID.isEmpty == true ? "Follow a board in Settings › Jira, or follow tickets here." : ""))
                } actions: {
                    if jira != nil { Button("Follow a Ticket…", systemImage: "plus") { following = true } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JiraBoardLayout(config: config, tickets: visible,
                                columns: config.mode == "board" ? jira?.columns(board: config.board) ?? [] : JiraBoardLayout.statusColumns(visible)) { pick($0) }
                    .environment(\.jiraSelectedKey, selectedKey)
            }
        }
        .sheet(item: $opened) { JiraIssueSheet(issue: $0, host: host) }
    }

    /// Clicking an issue selects it and opens its detail; clicking the selected one again unselects it.
    private func pick(_ ticket: JiraTicket) {
        if selectedKey == ticket.key {
            selectedKey = nil
        } else {
            selectedKey = ticket.key
            opened = ticket
        }
    }

    private var setupPrompt: some View {
        ContentUnavailableView {
            Label("Connect Jira", systemImage: "checklist")
        } description: {
            Text("Add your site, email and API token.")
        } actions: {
            Button("Connect Atlassian…") { host.openManager("atlassian") }
        }
    }
}

/// Columns (board mode with a known column layout) or a list; shared by the widget and its preview.
struct JiraBoardLayout: View {
    /// Column colours from to-do (grey) through work (blue, purple) to done (green).
    static func color(_ index: Int, of count: Int) -> Color {
        guard count > 1 else { return .blue }
        if index == 0 { return .gray }
        if index == count - 1 { return .green }
        return [Color.blue, .orange, .purple, .teal, .pink, .indigo][(index - 1) % 6]
    }

    /// Followed tickets come from many boards: one column per status, to do → in progress → done.
    static func statusColumns(_ tickets: [JiraTicket]) -> [JiraClient.Column] {
        let order = ["new": 0, "indeterminate": 1, "done": 2]
        var seen: [String: (rank: Int, ids: Set<String>)] = [:]
        for ticket in tickets {
            seen[ticket.statusName, default: (order[ticket.statusCategory] ?? 1, [])].ids.insert(ticket.statusID)
        }
        return seen.sorted { ($0.value.rank, $0.key) < ($1.value.rank, $1.key) }
            .map { JiraClient.Column(name: $0.key, statusIDs: Array($0.value.ids)) }
    }

    let config: JiraBoardWidget.Config
    let tickets: [JiraTicket]
    let columns: [JiraClient.Column]
    /// nil in previews: cards aren't tappable.
    let onSelect: ((JiraTicket) -> Void)?

    var body: some View {
        if !columns.isEmpty {
            GeometryReader { geometry in
                // Columns share the width when they fit, else keep 240 pt and scroll sideways.
                let spacing = 10.0
                let width = max(240, (geometry.size.width - spacing * Double(columns.count - 1)) / Double(columns.count))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(columns.enumerated()), id: \.element.name) { index, column in
                            let cards = tickets.filter { column.statusIDs.contains($0.statusID) }
                            BoardColumn(name: column.name, color: Self.color(index, of: columns.count), cards: cards, onSelect: onSelect)
                                .frame(width: width)
                                .frame(maxHeight: geometry.size.height, alignment: .top)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.visible)
            }
        } else {
            List(tickets) { issue in
                IssueRow(issue: issue).contentShape(.rect).onTapGesture { onSelect?(issue) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One board column: a lane with its name, count and cards.
private struct BoardColumn: View {
    let name: String
    let color: Color
    let cards: [JiraTicket]
    let onSelect: ((JiraTicket) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1)
                Text("\(cards.count)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            if cards.isEmpty {
                Text("Nothing here").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(cards) { issue in
                            IssueCard(issue: issue, accent: color).onTapGesture { onSelect?(issue) }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }
}

extension EnvironmentValues {
    /// The issue picked on the board, drawn as selected.
    @Entry var jiraSelectedKey: String? = nil
}

private struct IssueCard: View {
    let issue: JiraTicket
    var accent: Color = .accentColor
    @State private var hovering = false
    @Environment(\.jiraSelectedKey) private var selectedKey
    private var isSelected: Bool { selectedKey == issue.key }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.summary).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let assignee = issue.assignee {
                    Text(assignee.split(separator: " ").compactMap(\.first).prefix(2).map(String.init).joined())
                        .font(.caption2.bold())
                        .frame(width: 22, height: 22)
                        .background(.tint.opacity(0.22), in: .circle)
                        .help(assignee)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(.background.secondary), in: .rect(cornerRadius: 9))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9).fill(accent.opacity(0.8)).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? AnyShapeStyle(accent) : hovering ? AnyShapeStyle(accent.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.6)),
                                                                lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 6 : 2, y: 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct IssueRow: View {
    let issue: JiraTicket
    @Environment(\.jiraSelectedKey) private var selectedKey

    var body: some View {
        HStack {
            StatusPill(name: issue.statusName, category: issue.statusCategory)
            VStack(alignment: .leading) {
                Text(issue.summary).lineLimit(1)
                Text("\(issue.key) · \(issue.assignee ?? "Unassigned")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(selectedKey == issue.key ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
