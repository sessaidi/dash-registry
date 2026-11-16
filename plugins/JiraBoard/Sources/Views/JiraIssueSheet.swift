import AppKit
import DashKit
import DashKitUI
import SwiftUI

struct StatusPill: View {
    let name: String
    let category: String

    var body: some View {
        Badge(name, tone: category == "done" ? .success : category == "indeterminate" ? .info : .neutral)
    }
}

/// One issue, laid out like Jira's issue view: breadcrumb and title, the formatted description,
/// sub-tasks, linked issues and the activity on the left; status, agents, details, development
/// and the site's own fields on the right. Linked issues open in place, with a back button.
struct JiraIssueSheet: View {
    let issue: JiraTicket
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var history: [String] = []
    @State private var detail: JiraIssueDetail?
    @State private var pullRequests: (count: Int, state: String?)?
    /// This ticket's worktrees on this Mac, from the Agents plugin's scan (empty without it).
    @State private var worktrees: [JSONValue] = []
    @State private var transitions: [(id: String, name: String)] = []
    @State private var comment = ""
    @State private var error: String?
    @State private var busy = false
    @State private var reload = 0
    @State private var me = ""
    @State private var reactions: [String: [JiraClient.Reaction]] = [:]
    /// False when the site's reactions service didn't answer: no picker that can only fail.
    @State private var reactionsAvailable = false
    /// Reactions being sent ("comment|emoji"), so a double click doesn't race itself.
    @State private var reacting: Set<String> = []
    @State private var replyingTo: JiraIssueDetail.Comment?
    @State private var editing: String?
    @State private var editText = ""
    @State private var deleting: JiraIssueDetail.Comment?

    init(issue: JiraTicket, host: any ExtensionContext) {
        self.issue = issue
        self.host = host
        _key = State(initialValue: issue.key)
    }

    private var jira: JiraBoardFeature? { host.ext(JiraBoardFeature.self) }

    /// The Agents feature's tools, reached by id so this plugin doesn't link another plugin.
    private func agentsTool(_ name: String) -> DashiiTool? {
        host.extensions.first { $0.id == "agents" && host.isEnabled($0) }?.tools.first { $0.name == name }
    }

    private var startAgent: DashiiTool? { agentsTool("agents_start") }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { main.padding(20) }
                Divider()
                ScrollView { sidebar.padding(16) }.frame(width: 300)
            }
        }
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 620, idealHeight: 780)
        .environment(\.jiraSite, URL(string: issue.url)?.host())
        .task(id: "\(key)#\(reload)") { await load() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !history.isEmpty {
                Button("Back", systemImage: "chevron.left") { show(history.removeLast()) }
                    .labelStyle(.iconOnly)
            }
            breadcrumb
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let url = detail?.url ?? (key == issue.key ? URL(string: issue.url) : nil) {
                Link(destination: url) { Label("Open in Jira", systemImage: "arrow.up.right.square") }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if let project = detail?.project, !project.isEmpty {
                Text(project).foregroundStyle(.secondary)
                Text("/").foregroundStyle(.tertiary)
            }
            if let parent = detail?.parent {
                Button { open(parent.key) } label: {
                    HStack(spacing: 4) { IssueTypeIcon(type: parent.type); Text(parent.key) }
                }
                .buttonStyle(.link)
                Text("/").foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                IssueTypeIcon(type: detail?.issue.issueType ?? (key == issue.key ? issue.issueType : nil))
                Text(key).font(.callout.monospaced().weight(.semibold)).textSelection(.enabled)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    // MARK: Main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(detail?.issue.summary ?? (key == issue.key ? issue.summary : key))
                .font(.title.bold())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            if let detail {
                if !detail.criteria.isEmpty {
                    Fold("Acceptance criteria", count: detail.criteria.count) { CriteriaTile(criteria: detail.criteria) }
                }
                Fold("Description") {
                    ADFView(document: detail.description)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary.opacity(0.6), in: .rect(cornerRadius: 8))
                }
                if !detail.subtasks.isEmpty {
                    Fold("Sub-tasks", count: detail.subtasks.count) {
                        progress(detail.subtasks)
                        IssueList(issues: detail.subtasks, open: open)
                    }
                }
                if !detail.links.isEmpty {
                    Fold("Linked issues", count: detail.links.count) {
                        ForEach(Dictionary(grouping: detail.links, by: \.relation).sorted { $0.key < $1.key }, id: \.key) { relation, items in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(relation).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                IssueList(issues: items, open: open)
                            }
                        }
                    }
                }
                activity(detail)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progress(_ subtasks: [JiraIssueDetail.Related]) -> some View {
        let done = subtasks.filter { $0.statusCategory == "done" }.count
        return HStack {
            ProgressView(value: Double(done), total: Double(max(subtasks.count, 1))).tint(.green)
            Text("\(done) of \(subtasks.count) done").font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private func activity(_ detail: JiraIssueDetail) -> some View {
        Fold("Activity", count: detail.comments.count) {
            composer
            ForEach(detail.comments) { comment in commentRow(comment) }
        }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                guard let comment = deleting else { return }
                run {
                    try await jira?.client.deleteComment(key, id: comment.id)
                    reload += 1
                }
            }
        } message: {
            Text("It's removed from Jira for everyone.")
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let replyingTo {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    Text("Replying to \(replyingTo.author)").font(.caption.weight(.semibold))
                    Text(JiraClient.plainText(replyingTo.body)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel Reply", systemImage: "xmark") { self.replyingTo = nil }.labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .padding(8)
                .background(.tint.opacity(0.08), in: .rect(cornerRadius: 6))
            }
            TextField(replyingTo == nil ? "Add a comment…" : "Write a reply…", text: $comment, axis: .vertical)
                .lineLimit(2...8)
                .textFieldStyle(.plain)
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            if !comment.isEmpty {
                Button(replyingTo == nil ? "Save" : "Reply") {
                    let text = comment
                    let parent = replyingTo
                    run {
                        guard let client = try jira?.client else { return }
                        if let parent {
                            try await client.comment(key, document: JiraClient.reply(
                                to: parent.authorID, name: parent.author, quoting: JiraClient.plainText(parent.body), text: text))
                        } else {
                            try await client.comment(key, text: text)
                        }
                        comment = ""
                        replyingTo = nil
                        reload += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy)
            }
        }
    }

    private func commentRow(_ comment: JiraIssueDetail.Comment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: comment.author, size: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.callout.weight(.semibold))
                    if let created = comment.created {
                        Text(created, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            .help(created.formatted(date: .complete, time: .shortened))
                    }
                    if comment.edited { Text("Edited").font(.caption).foregroundStyle(.tertiary) }
                }
                if editing == comment.id {
                    TextField("Comment", text: $editText, axis: .vertical)
                        .lineLimit(2...10)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") {
                            let text = editText
                            run {
                                try await jira?.client.editComment(key, id: comment.id, text: text)
                                editing = nil
                                reload += 1
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(editText.isEmpty || busy)
                        Button("Cancel") { editing = nil }
                    }
                    .controlSize(.small)
                } else {
                    ADFView(document: comment.body).font(.callout)
                }
                commentActions(comment)
            }
        }
        .padding(.top, 4)
    }

    /// Reactions as chips (yours highlighted, a click toggles), a picker for a new one, then reply,
    /// and edit or delete on your own comments.
    private func commentActions(_ comment: JiraIssueDetail.Comment) -> some View {
        let chosen = reactions[comment.id] ?? []
        return HStack(spacing: 6) {
            ForEach(chosen, id: \.emojiID) { reaction in
                Button { toggle(reaction.emojiID, on: comment) } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        Text("\(reaction.count)").font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(reaction.mine ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.background.secondary), in: .capsule)
                    .overlay(Capsule().strokeBorder(reaction.mine ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
                }
                .buttonStyle(.plain)
            }
            if reactionsAvailable {
                Menu {
                    ForEach(JiraClient.Reaction.choices, id: \.self) { id in
                        Button(JiraClient.Reaction.emoji(id)) { toggle(id, on: comment) }
                    }
                } label: {
                    Image(systemName: "face.smiling")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("React")
            }
            Button("Reply") { replyingTo = comment }
            if !me.isEmpty, comment.authorID == me {
                // Editing here is plain text: a comment with links, mentions, lists or formatting
                // would lose them, so those are edited in Jira.
                if JiraClient.isPlainText(comment.body) {
                    Button("Edit") { editText = JiraClient.plainText(comment.body); editing = comment.id }
                } else if let url = detail?.url {
                    Link("Edit in Jira", destination: url).help("It has formatting this editor would remove.")
                }
                Button("Delete") { deleting = comment }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Adds or removes the user's reaction at once, then tells Jira; puts it back if Jira refuses.
    private func toggle(_ emojiID: String, on comment: JiraIssueDetail.Comment) {
        let sending = "\(comment.id)|\(emojiID)"
        guard reacting.insert(sending).inserted else { return }
        let before = reactions[comment.id] ?? []
        var after = before
        let removing = before.first { $0.emojiID == emojiID }?.mine == true
        if let index = after.firstIndex(where: { $0.emojiID == emojiID }) {
            after[index].count += removing ? -1 : 1
            after[index].mine = !removing
            if after[index].count <= 0 { after.remove(at: index) }
        } else {
            after.append(JiraClient.Reaction(emojiID: emojiID, count: 1, mine: true))
        }
        reactions[comment.id] = after
        Task {
            defer { reacting.remove(sending) }
            do {
                guard let client = try jira?.client else { return }
                if removing { try await client.unreact(commentID: comment.id, emojiID: emojiID) }
                else { try await client.react(commentID: comment.id, emojiID: emojiID) }
            } catch {
                reactions[comment.id] = before
                self.error = "Jira didn't take the reaction: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(transitions, id: \.id) { transition in
                    Button(transition.name) {
                        run {
                            _ = try await jira?.move(key, toStatus: transition.name)
                            reload += 1
                        }
                    }
                }
            } label: {
                Text(detail?.issue.statusName ?? (key == issue.key ? issue.statusName : "Status"))
            }
            .fixedSize()
            .tint(Self.tint(detail?.issue.statusCategory ?? issue.statusCategory))
            .disabled(transitions.isEmpty || busy)
            .help("Move to another status")
            HStack(spacing: 8) {
                Button("Ask Dashii", systemImage: "sparkles") {
                    host.askDashii("Look at Jira issue \(key) and suggest how to approach it.")
                    dismiss()
                }
                Button("Start Agent", systemImage: "hammer") {
                    run {
                        guard let startAgent else { return }
                        let session = try await startAgent.run(["issue_key": .string(key)])
                        dismiss()
                        // The Agents plugin owns its chat windows; ask it to open this one.
                        if let id = session["id"]?.string {
                            _ = try? await agentsTool("agents_open")?.run(["session_id": .string(id)])
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || startAgent == nil)
            }
            if let detail { details(detail) }
        }
    }

    @ViewBuilder private func details(_ detail: JiraIssueDetail) -> some View {
        Panel("Details") {
            FieldRow("Assignee") { person(detail.issue.assignee, empty: "Unassigned") }
            FieldRow("Reporter") { person(detail.reporter, empty: "—") }
            FieldRow("Priority") {
                if let priority = detail.issue.priority {
                    HStack(spacing: 4) { PriorityIcon(priority: priority); Text(priority) }
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            if let parent = detail.parent {
                FieldRow("Parent") {
                    Button { open(parent.key) } label: {
                        HStack(spacing: 4) {
                            IssueTypeIcon(type: parent.type)
                            Text("\(parent.key) \(parent.summary)").lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            FieldRow("Labels") { chips(detail.issue.labels, empty: "None") }
            if let points = detail.storyPoints { FieldRow("Story points") { Badge(points, tone: .neutral) } }
            if let sprint = detail.sprint { FieldRow("Sprint") { Text(sprint).foregroundStyle(.tint) } }
            if !detail.components.isEmpty { FieldRow("Components") { chips(detail.components, empty: "") } }
            if !detail.fixVersions.isEmpty { FieldRow("Fix versions") { chips(detail.fixVersions, empty: "") } }
            if let due = detail.due { FieldRow("Due date") { Text(due) } }
        }
        Panel("Development") {
            if let pullRequests, pullRequests.count > 0 {
                HStack {
                    Label("\(pullRequests.count) pull request\(pullRequests.count == 1 ? "" : "s")", systemImage: "arrow.triangle.pull")
                    if let state = pullRequests.state {
                        Badge(state.capitalized, tone: state == "MERGED" ? .success : state == "OPEN" ? .info : .neutral)
                    }
                }
            } else {
                Label("No linked pull requests", systemImage: "arrow.triangle.pull").foregroundStyle(.secondary)
            }
            ForEach(Array(worktrees.enumerated()), id: \.offset) { _, tree in TicketWorktreeRow(tree: tree) }
        }
        .font(.callout)
        if !detail.fields.isEmpty {
            Panel("More fields", expanded: false) {
                ForEach(detail.fields) { field in FieldRow(field.name) { Text(field.value).textSelection(.enabled) } }
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            if let created = detail.created { Text("Created \(created, format: .relative(presentation: .named))") }
            if let updated = detail.issue.updated { Text("Updated \(updated, format: .relative(presentation: .named))") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func person(_ name: String?, empty: String) -> some View {
        if let name {
            HStack(spacing: 6) { Avatar(name: name, size: 20); Text(name) }
        } else {
            Text(empty).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func chips(_ items: [String], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 4) { ForEach(items, id: \.self) { Badge($0, tone: .neutral) } }
        }
    }

    static func tint(_ category: String) -> Color {
        category == "done" ? .green : category == "indeterminate" ? .blue : .gray
    }

    // MARK: Loading

    private func open(_ other: String) {
        guard other != key else { return }
        history.append(key)
        show(other)
    }

    /// Switches to another issue, dropping everything that belonged to the one shown, so no
    /// action (a status move, a reply) can reach the new issue with the old one's data.
    private func show(_ other: String) {
        detail = nil
        transitions = []
        pullRequests = nil
        worktrees = []
        reactions = [:]
        reactionsAvailable = false
        replyingTo = nil
        editing = nil
        editText = ""
        deleting = nil
        comment = ""
        error = nil
        key = other
    }

    /// Loads `key`. The task is cancelled when the issue changes; nothing it read afterwards is
    /// kept, so a slow answer for the previous issue can't land on this one.
    private func load() async {
        guard let client = try? jira?.client else { return }
        let key = key
        var current: Bool { !Task.isCancelled && self.key == key }
        error = nil
        do {
            let loaded = try await client.issueView(key)
            guard current else { return }
            detail = loaded
            if me.isEmpty { me = (try? await client.myAccountID()) ?? "" }
            let read = try? await client.reactions(commentIDs: loaded.comments.map(\.id))
            let moves = (try? await client.transitions(key)) ?? []
            let prs = loaded.issue.id.isEmpty ? nil : try? await client.pullRequests(issueID: loaded.issue.id)
            let trees = await ticketWorktrees(key)
            guard current else { return }
            worktrees = trees
            reactions = read ?? [:]
            reactionsAvailable = read != nil
            transitions = moves
            pullRequests = prs
        } catch {
            guard current else { return }
            self.error = error.localizedDescription
        }
    }

    /// The worktrees whose branch names this ticket, from the Agents plugin (`worktrees_list`).
    private func ticketWorktrees(_ key: String) async -> [JSONValue] {
        guard let tool = host.extensions.filter({ host.isEnabled($0) }).flatMap(\.tools).first(where: { $0.name == "worktrees_list" }) else { return [] }
        return (try? await tool.run(["ticket": .string(key)]))?["worktrees"]?.array ?? []
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: - Pieces

/// The acceptance criteria as a tile: numbered rows (ticked when Jira tracks them), with a
/// progress bar when some are ticked.
private struct CriteriaTile: View {
    let criteria: [JiraIssueDetail.Criterion]

    var body: some View {
        let tracked = criteria.filter { $0.done != nil }
        let done = tracked.filter { $0.done == true }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("\(criteria.count) criteria", systemImage: "checklist").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                Spacer()
                if !tracked.isEmpty {
                    ProgressView(value: Double(done), total: Double(tracked.count)).tint(.green).frame(width: 120)
                    Text("\(done) of \(tracked.count) met").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            ForEach(criteria) { criterion in
                if criterion.id > 0 { Divider().padding(.leading, 46) }
                HStack(alignment: .top, spacing: 12) {
                    marker(criterion)
                    ADFBlocks(nodes: criterion.content)
                        .foregroundStyle(criterion.done == true ? .secondary : .primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(.tint.opacity(0.05), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.3)))
    }

    @ViewBuilder private func marker(_ criterion: JiraIssueDetail.Criterion) -> some View {
        switch criterion.done {
        case true?:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green).frame(width: 22)
        case false?:
            Image(systemName: "circle").font(.title3).foregroundStyle(.secondary).frame(width: 22)
        case nil:
            Text("\(criterion.id + 1)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.15), in: .circle)
        }
    }
}

/// A titled section that folds, like Jira's.
private struct Fold<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder let content: () -> Content
    @State private var expanded = true

    init(_ title: String, count: Int? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.bold()).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.headline)
                    if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded { content() }
        }
    }
}

/// A boxed sidebar section that folds.
private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var expanded: Bool

    init(_ title: String, expanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.bold()).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded { VStack(alignment: .leading, spacing: 12) { content() } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

private struct FieldRow<Value: View>: View {
    let name: String
    @ViewBuilder let value: () -> Value

    init(_ name: String, @ViewBuilder value: @escaping () -> Value) {
        self.name = name
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            value().font(.callout)
        }
    }
}

/// Issues as rows: type, key, summary, priority, assignee, status. A row opens its issue.
private struct IssueList: View {
    let issues: [JiraIssueDetail.Related]
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // By position: one issue can be linked twice the same way.
            ForEach(Array(issues.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                Button { open(item.key) } label: {
                    HStack(spacing: 8) {
                        IssueTypeIcon(type: item.type)
                        Text(item.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .strikethrough(item.statusCategory == "done")
                        Text(item.summary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        if let priority = item.priority { PriorityIcon(priority: priority).help(priority) }
                        if let assignee = item.assignee { Avatar(name: assignee, size: 20).help(assignee) }
                        StatusPill(name: item.status, category: item.statusCategory)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// Short values that wrap onto as many lines as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(width: bounds.width, subviews: subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + line), points)
    }
}

/// Initials on a colour picked from the name, so a person keeps their colour.
struct Avatar: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let palette: [Color] = [.purple, .green, .blue, .orange, .pink, .teal, .indigo, .red]
        let color = palette[Int(name.unicodeScalars.reduce(UInt(0)) { $0 &+ UInt($1.value) } % UInt(palette.count))]
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
    }
}

struct IssueTypeIcon: View {
    let type: String?

    var body: some View {
        let (symbol, color): (String, Color) = switch type?.lowercased() ?? "" {
        case "bug": ("ladybug.fill", .red)
        case "story": ("bookmark.fill", .green)
        case "epic": ("bolt.fill", .purple)
        case "sub-task", "subtask": ("square.split.bottomrightquarter.fill", .blue)
        case "": ("circle.dashed", .secondary)
        default: ("checkmark.square.fill", .blue)
        }
        Image(systemName: symbol).foregroundStyle(color).font(.caption).help(type ?? "")
    }
}

struct PriorityIcon: View {
    let priority: String

    var body: some View {
        let (symbol, color): (String, Color) = switch priority.lowercased() {
        case "highest", "blocker", "critical": ("chevron.up.2", .red)
        case "high", "major": ("chevron.up", .orange)
        case "low", "minor": ("chevron.down", .blue)
        case "lowest", "trivial": ("chevron.down.2", .blue)
        default: ("equal", .yellow)
        }
        Image(systemName: symbol).foregroundStyle(color).font(.caption.bold())
    }
}

/// A worktree of the ticket: its branch, its PR (open, merged, closed) and what it needs.
private struct TicketWorktreeRow: View {
    let tree: JSONValue

    var body: some View {
        let status = (tree["status"]?.array ?? []).compactMap(\.string)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Button(tree["branch"]?.string ?? tree["name"]?.string ?? "worktree") {
                    if let path = tree["path"]?.string { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .buttonStyle(.link)
                .help(tree["path"]?.string ?? "")
                if let pr = tree["pr"], pr != .null, let number = pr["number"]?.int {
                    let state = pr["state"]?.string ?? "open"
                    Link(destination: URL(string: pr["url"]?.string ?? "") ?? URL(string: "https://github.com")!) {
                        Badge(state == "merged" ? "#\(number) merged" : state == "closed" ? "#\(number) closed" : state == "draft" ? "#\(number) draft" : "#\(number)",
                              tone: state == "merged" ? .success : state == "closed" ? .neutral : .info)
                    }
                }
            }
            let needs = status.filter { !$0.hasPrefix("#") && !$0.hasPrefix("PR ") && !$0.hasPrefix("Draft ") && $0 != "No PR" }
            if !needs.isEmpty {
                Text(needs.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
