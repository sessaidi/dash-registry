import DashKit
import DashKitUI
import SwiftUI

/// One line of a unified diff, with its old and new line numbers.
struct DiffLine: Equatable {
    enum Kind { case hunk, added, removed, context, note }
    let kind: Kind
    let text: String
    let old: Int?
    let new: Int?

    private nonisolated(unsafe) static let hunkHeader = try! Regex(#"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

    /// Parses a GitHub `patch` (unified diff hunks).
    static func parse(_ patch: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0, new = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                // @@ -63,17 +63,11 @@ context
                if let match = try? Self.hunkHeader.firstMatch(in: line) {
                    old = Int(match.output[1].substring ?? "") ?? 0
                    new = Int(match.output[2].substring ?? "") ?? 0
                }
                lines.append(DiffLine(kind: .hunk, text: line, old: nil, new: nil))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), old: nil, new: new))
                new += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), old: old, new: nil))
                old += 1
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(kind: .note, text: line, old: nil, new: nil))
            } else {
                lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: old, new: new))
                old += 1
                new += 1
            }
        }
        return lines
    }
}

/// A file's diff as GitHub draws it: green added lines, red removed ones, blue hunk headers and
/// both line numbers.
struct DiffView: View {
    let patch: String

    var body: some View {
        let lines = DiffLine.parse(patch)
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        number(line.old)
                        number(line.new)
                        Text(marker(line.kind)).frame(width: 16).foregroundStyle(foreground(line.kind))
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .hunk || line.kind == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
            .textSelection(.enabled)
        }
        .background(.background.secondary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing).padding(.trailing, 6)
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private func foreground(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? .green : kind == .removed ? .red : .secondary
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        case .hunk: .blue.opacity(0.12)
        default: .clear
        }
    }
}

/// GitHub's five squares: how much of a file's change is added (green) and removed (red).
struct ChangeSquares: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = max(additions + deletions, 1)
        let green = Int((Double(additions) / Double(total) * 5).rounded())
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(additions + deletions == 0 ? Color.secondary.opacity(0.3) : index < green ? .green : .red)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// A changed file's status: added, removed, renamed or modified.
struct FileStatusBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "added": Badge("added", tone: .success)
        case "removed": Badge("removed", tone: .danger)
        case "renamed": Badge("renamed", tone: .info)
        default: Badge("modified", tone: .warning)
        }
    }
}
