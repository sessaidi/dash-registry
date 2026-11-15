import DashKit
import DashKitUI
import SwiftUI

/// The pull request's conversation on GitHub, answered by the user: reply to threads, resolve
/// them, comment, approve or request changes. Every send is a button the user presses and
/// confirms; Dashii only suggests better wording (`Improve with Dashii`) and never posts.
struct PRConversationView: View {
    let pr: PullRequest
    let host: any ExtensionContext
    let feature: PullRequestsFeature
    /// The user's review notes from "Review with Dashii", to start a review from.
    var notes: String = ""
    @State private var conversation: PRConversation?
    @State private var error: String?
    @State private var showResolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let conversation {
                let threads = conversation.threads.filter { showResolved || !$0.isResolved }
                Panel(title: "Threads on the code (\(conversation.unresolved) open)", systemImage: "text.bubble", tint: conversation.unresolved > 0 ? .orange : .green) {
                    Toggle("Show resolved", isOn: $showResolved).toggleStyle(.switch).controlSize(.small)
                    if threads.isEmpty { Text(conversation.threads.isEmpty ? "No comments on the code." : "All threads are resolved.").foregroundStyle(.secondary) }
                    ForEach(threads) { thread in ThreadCard(thread: thread, pr: pr, host: host, feature: feature, reload: load) }
                }
                Panel(title: "Conversation", systemImage: "bubble.left.and.bubble.right", tint: .blue) {
                    ForEach(conversation.reviews.filter { !$0.body.isEmpty || $0.state != "COMMENTED" }, id: \.submittedAt) { review in
                        CommentRow(author: review.author, text: review.body, date: review.submittedAt, state: review.state, host: host)
                    }
                    ForEach(conversation.comments) { CommentRow(author: $0.author, text: $0.body, date: $0.createdAt, host: host) }
                    Composer(placeholder: "Comment on the pull request…", purpose: "a comment on the pull request's conversation",
                             pr: pr, feature: feature, actions: [.init(title: "Comment", event: nil)]) { text, _ in
                        try await feature.client.comment(pr.repo, pr.number, body: text)
                        await load()
                    }
                }
                Panel(title: "Your review", systemImage: "checkmark.seal", tint: .purple) {
                    Composer(placeholder: "What you think: what's good, what must change…", purpose: "the user's review of the pull request",
                             pr: pr, feature: feature, initial: notes,
                             actions: [.init(title: "Approve", event: "APPROVE"), .init(title: "Request Changes", event: "REQUEST_CHANGES"),
                                       .init(title: "Comment", event: "COMMENT")]) { text, event in
                        try await feature.client.submitReview(pr.repo, pr.number, event: event ?? "COMMENT", body: text)
                        await load()
                    }
                    Text("Started from your review notes (Review with Dashii) when you have some.").font(.caption).foregroundStyle(.secondary)
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            conversation = try await feature.client.conversation(pr.repo, pr.number)
            error = nil
        } catch {
            self.error = "Couldn't read the conversation: \(error.localizedDescription)"
        }
    }
}

private struct ThreadCard: View {
    let thread: PRConversation.Thread
    let pr: PullRequest
    let host: any ExtensionContext
    let feature: PullRequestsFeature
    let reload: () async -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(thread.line.map { "\(thread.path):\($0)" } ?? thread.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                if thread.isOutdated { Badge("outdated", tone: .neutral) }
                if thread.isResolved { Badge("resolved", tone: .success) }
                Spacer()
                Button(thread.isResolved ? "Unresolve" : "Resolve", systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark.circle") {
                    busy = true
                    Task {
                        do { try await feature.client.setResolved(threadID: thread.id, !thread.isResolved); await reload() } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                .controlSize(.small)
                .disabled(busy)
            }
            ForEach(thread.comments) { CommentRow(author: $0.author, text: $0.body, date: $0.createdAt, host: host) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !thread.isResolved, let first = thread.comments.first {
                Composer(placeholder: "Reply…", purpose: "a reply in a review thread on \(thread.path)",
                         context: thread.comments.map { "\($0.author): \($0.body)" }.joined(separator: "\n\n"),
                         pr: pr, feature: feature, actions: [.init(title: "Reply", event: nil)]) { text, _ in
                    try await feature.client.reply(pr.repo, pr.number, to: first.id, body: text)
                    await reload()
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
        .opacity(thread.isResolved ? 0.7 : 1)
    }
}

private struct CommentRow: View {
    let author: String
    let text: String
    let date: Date?
    var state: String? = nil
    let host: any ExtensionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(author).font(.callout.weight(.semibold))
                if let state {
                    Badge(state.replacingOccurrences(of: "_", with: " ").capitalized,
                          tone: state == "APPROVED" ? .success : state == "CHANGES_REQUESTED" ? .danger : .neutral)
                }
                if let date { Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
            }
            if !text.isEmpty { host.markdown(text) }
        }
    }
}

/// What the user writes, with Dashii's suggested wording on request, and the send buttons. Each
/// send asks for confirmation: it posts on GitHub as the user.
struct Composer: View {
    struct Action: Hashable {
        let title: String
        /// The review event (APPROVE, REQUEST_CHANGES, COMMENT), nil for a reply or comment.
        let event: String?
    }

    let placeholder: String
    /// What the text is, for Dashii: "a reply in a review thread on api/x.swift".
    let purpose: String
    var context = ""
    let pr: PullRequest
    let feature: PullRequestsFeature
    var initial = ""
    let actions: [Action]
    let send: (String, String?) async throws -> Void
    @State private var text = ""
    @State private var suggestion: PullRequestsFeature.Rewording?
    @State private var improving = false
    @State private var confirming: Action?
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 54, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text(placeholder).font(.callout).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false) }
                }
            if let suggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Dashii suggests", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.purple)
                    Text(suggestion.rewrite).font(.callout).textSelection(.enabled)
                    ForEach(suggestion.notes, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Use It") { text = suggestion.rewrite; self.suggestion = nil }
                        Button("Dismiss") { self.suggestion = nil }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.purple.opacity(0.1), in: .rect(cornerRadius: 6))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Improve with Dashii", systemImage: "sparkles") { improve() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || improving)
                if improving { ProgressView().controlSize(.small) }
                Spacer()
                ForEach(actions, id: \.self) { action in
                    Button(action.title) { confirming = action }
                        .buttonStyle(action == actions.first ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
                        .disabled(sending || (action.event != "APPROVE" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .controlSize(.small)
        }
        .onAppear { if text.isEmpty { text = initial } }
        .confirmationDialog("Post on GitHub as you?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { action in
            Button(action.title) { post(action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everyone on \(pr.repo)#\(pr.number) will see it.")
        }
    }

    private func improve() {
        improving = true
        error = nil
        Task {
            do { suggestion = try await feature.reword(text, purpose: purpose, context: context, pr: pr) } catch { self.error = error.localizedDescription }
            improving = false
        }
    }

    private func post(_ action: Action) {
        sending = true
        error = nil
        Task {
            do {
                try await send(text.trimmingCharacters(in: .whitespacesAndNewlines), action.event)
                text = ""
                suggestion = nil
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// A button style chosen at run time.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
