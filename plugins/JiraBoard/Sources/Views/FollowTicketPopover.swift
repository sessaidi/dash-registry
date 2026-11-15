import DashKit
import DashKitUI
import SwiftUI

/// Follow tickets from the widget: a key, a browse link, or words to search; and the ones
/// followed, to unfollow. Following is local: nothing changes in Jira.
struct FollowTicketPopover: View {
    let jira: JiraBoardFeature
    @State private var query = ""
    @State private var results: [JiraClient.Issue] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow a ticket").font(.headline)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("LAF-1234, a Jira link, or words to search", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            if let key = directKey {
                row(key: key, title: jira.issue(key)?.summary ?? "Follow \(key)", followed: jira.followedKeys.contains(key))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(results, id: \.key) { issue in
                            row(key: issue.key, title: issue.summary, subtitle: issue.statusName, followed: jira.followedKeys.contains(issue.key))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if !jira.followedKeys.isEmpty {
                Divider()
                Text("Following \(jira.followedKeys.count)").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(jira.followedKeys, id: \.self) { key in
                            row(key: key, title: jira.issue(key)?.summary ?? "", subtitle: jira.issue(key)?.statusName, followed: true)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            Text("Followed tickets sync into the board; nothing changes in Jira.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 420)
        .task(id: query) {
            // Words search Jira after a pause; keys and links follow directly.
            guard directKey == nil, query.trimmingCharacters(in: .whitespaces).count >= 3 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    /// A key typed or found in a pasted link (…/browse/LAF-123, ?selectedIssue=LAF-123).
    private var directKey: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if JiraBoardFeature.isIssueKey(text) { return text }
        if let match = text.firstMatch(of: /(?:BROWSE\/|SELECTEDISSUE=)([A-Z][A-Z0-9_]+-\d+)/) { return String(match.output.1) }
        return nil
    }

    private func submit() {
        if let key = directKey {
            Task { await jira.follow(key) }
            query = ""
        } else {
            Task { await runSearch() }
        }
    }

    private func runSearch() async {
        let words = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        guard !words.isEmpty else { return }
        searching = true
        error = nil
        do {
            results = try await jira.client.search("text ~ \"\(words)\" ORDER BY updated DESC", limit: 15)
        } catch {
            self.error = error.localizedDescription
        }
        searching = false
    }

    private func row(key: String, title: String, subtitle: String? = nil, followed: Bool) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.12), in: .capsule)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? key : title).font(.callout).lineLimit(1)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 6)
            if followed {
                Button("Unfollow") { Task { await jira.unfollow(key) } }.controlSize(.small)
            } else {
                Button("Follow") { Task { await jira.follow(key) } }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}
