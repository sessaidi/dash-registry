import AppKit
import DashKit
import Foundation
import Observation
import SwiftUI

// MARK: - Diff

/// One file's changes against the base: its hunks of lines.
struct FileDiff: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable { case added, modified, deleted, renamed }

    struct Line: Hashable, Sendable {
        enum Kind: Sendable { case context, added, removed }
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
    }

    struct Hunk: Hashable, Sendable {
        let header: String
        let lines: [Line]
    }

    let path: String
    let oldPath: String?
    let status: Status
    let hunks: [Hunk]
    var id: String { path }
    var additions: Int { hunks.flatMap(\.lines).filter { $0.kind == .added }.count }
    var deletions: Int { hunks.flatMap(\.lines).filter { $0.kind == .removed }.count }
    /// Line numbers (new file) that were added or changed.
    var changedLines: Set<Int> { Set(hunks.flatMap(\.lines).compactMap { $0.kind == .added ? $0.new : nil }) }
    /// The first changed line, to open the file at.
    var firstChange: Int {
        let lines = hunks.first?.lines ?? []
        // The first added line; for a removal, the line now in its place.
        guard let index = lines.firstIndex(where: { $0.kind != .context }) else { return lines.first?.new ?? 1 }
        return lines[index...].first { $0.new != nil }?.new ?? lines[..<index].last?.new ?? 1
    }
}

enum DiffParser {
    /// Parses `git diff` unified output (with `--no-color`).
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var path = ""
        var oldPath: String?
        var status = FileDiff.Status.modified
        var hunks: [FileDiff.Hunk] = []
        var header = ""
        var lines: [FileDiff.Line] = []
        var old = 0
        var new = 0
        var inFile = false

        func closeHunk() {
            if !header.isEmpty { hunks.append(.init(header: header, lines: lines)) }
            header = ""
            lines = []
        }
        func closeFile() {
            closeHunk()
            if inFile, !path.isEmpty { files.append(FileDiff(path: path, oldPath: oldPath, status: status, hunks: hunks)) }
            hunks = []
            oldPath = nil
            status = .modified
            inFile = false
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                closeFile()
                inFile = true
                // diff --git a/x b/y
                if let range = raw.range(of: " b/", options: .backwards) { path = String(raw[range.upperBound...]) }
                continue
            }
            guard inFile else { continue }
            if raw.hasPrefix("new file mode") { status = .added; continue }
            if raw.hasPrefix("deleted file mode") { status = .deleted; continue }
            if raw.hasPrefix("rename from ") { oldPath = String(raw.dropFirst(12)); status = .renamed; continue }
            if raw.hasPrefix("rename to ") { path = String(raw.dropFirst(10)); continue }
            if raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                if raw.hasPrefix("+++ b/") { path = String(raw.dropFirst(6)) }
                continue
            }
            if raw.hasPrefix("@@") {
                closeHunk()
                header = raw
                // @@ -12,7 +12,9 @@
                let numbers = raw.split(separator: " ").dropFirst().prefix(2)
                old = Int(numbers.first?.dropFirst().split(separator: ",").first ?? "") ?? 0
                new = Int(numbers.dropFirst().first?.dropFirst().split(separator: ",").first ?? "") ?? 0
                continue
            }
            guard !header.isEmpty else { continue }
            if raw.hasPrefix("+") {
                lines.append(.init(kind: .added, old: nil, new: new, text: String(raw.dropFirst())))
                new += 1
            } else if raw.hasPrefix("-") {
                lines.append(.init(kind: .removed, old: old, new: nil, text: String(raw.dropFirst())))
                old += 1
            } else if raw.hasPrefix(" ") || raw.isEmpty {
                lines.append(.init(kind: .context, old: old, new: new, text: String(raw.dropFirst())))
                old += 1
                new += 1
            }
        }
        closeFile()
        return files
    }

    /// An untracked file as an all-added diff.
    static func added(path: String, contents: String) -> FileDiff {
        let lines = contents.components(separatedBy: "\n")
        let body = (contents.hasSuffix("\n") ? lines.dropLast() : lines[...]).enumerated().map {
            FileDiff.Line(kind: .added, old: nil, new: $0.offset + 1, text: $0.element)
        }
        return FileDiff(path: path, oldPath: nil, status: .added, hunks: [.init(header: "@@ -0,0 +1,\(body.count) @@ (untracked)", lines: Array(body))])
    }
}

// MARK: - Editors

/// The editor files open in, at the right line.
enum Editor: String, CaseIterable, Identifiable, Sendable {
    case vscode, cursor, zed, goland, neovim
    var id: String { rawValue }

    var name: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .goland: "GoLand"
        case .neovim: "Neovim (Terminal)"
        }
    }

    var bundleID: String {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .zed: "dev.zed.Zed"
        case .goland: "com.jetbrains.goland"
        case .neovim: "com.apple.Terminal"
        }
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// The command that does the same, shown in tooltips.
    func command(file: String, line: Int, project: String) -> String {
        switch self {
        case .vscode: "code -g '\(file):\(line)'"
        case .cursor: "cursor -g '\(file):\(line)'"
        case .zed: "zed '\(file):\(line)'"
        case .goland: "open -na GoLand.app --args '\(project)' --line \(line) '\(file)'"
        case .neovim: "cd '\(project)' && nvim +\(line) '\(file)'"
        }
    }

    /// Opens `file` (absolute) at `line`, in the project folder `project`.
    @MainActor
    func open(file: String, line: Int, project: String) {
        switch self {
        case .vscode, .cursor:
            // vscode://file/<path>:<line>  /  cursor://file/<path>:<line>
            let scheme = self == .vscode ? "vscode" : "cursor"
            if let url = URL(string: "\(scheme)://file\(file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file):\(line)") {
                NSWorkspace.shared.open(url)
            }
        case .zed:
            if let url = URL(string: "zed://file\(file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file):\(line)") {
                NSWorkspace.shared.open(url)
            }
        case .goland:
            run("/usr/bin/open", ["-na", "GoLand.app", "--args", project, "--line", "\(line)", file])
        case .neovim:
            let script = "cd \(Self.quote(project)) && nvim +\(line) \(Self.quote(file))"
            run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"",
                                       "-e", "tell application \"Terminal\" to activate"])
        }
    }

    private func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
    }

    static func quote(_ text: String) -> String { "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'" }

    /// The user's choice (Settings › Agents), else the first installed.
    static var preferred: Editor {
        if let saved = DashStorage.defaults.string(forKey: "agents.editor").flatMap(Editor.init(rawValue:)) { return saved }
        return allCases.first { $0.isInstalled } ?? .vscode
    }
}

// MARK: - Model

/// A worktree's files and changes, refreshed while the agent works.
@MainActor
@Observable
final class WorktreeState {
    let root: URL
    let base: String
    private(set) var files: [String] = []
    private(set) var diffs: [FileDiff] = []
    private(set) var error: String?
    private(set) var loading = false
    var selectedFile: String?
    var selectedLine: Int?

    init(root: URL, base: String) {
        self.root = root
        self.base = base
    }

    func diff(for path: String) -> FileDiff? { diffs.first { $0.path == path } }

    func status(of path: String) -> FileDiff.Status? { diff(for: path)?.status }

    /// Files and the diff against where the branch left its base (commits and uncommitted work,
    /// plus untracked files).
    func reload() async {
        loading = true
        defer { loading = false }
        do {
            let root = root
            let base = base
            let (files, diffs) = try await Task.detached {
                let listed = try Self.git(["ls-files", "-co", "--exclude-standard"], in: root)
                let files = listed.split(separator: "\n").map(String.init).sorted()
                let mergeBase = (try? Self.git(["merge-base", base, "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)) ?? base
                var diffs = DiffParser.parse(try Self.git(["diff", "--no-color", "-M", mergeBase], in: root))
                let untracked = try Self.git(["ls-files", "--others", "--exclude-standard"], in: root).split(separator: "\n").map(String.init)
                for path in untracked where !diffs.contains(where: { $0.path == path }) {
                    if let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) { diffs.append(DiffParser.added(path: path, contents: text)) }
                }
                return (files, diffs.sorted { $0.path < $1.path })
            }.value
            self.files = files
            self.diffs = diffs
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError("git \(arguments.first ?? "") failed in \(folder.lastPathComponent)") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Shows a file, at a line.
    func reveal(_ path: String, line: Int?) {
        selectedFile = path
        selectedLine = line
    }

    func open(_ path: String, line: Int?) {
        Editor.preferred.open(file: root.appending(path: path).path, line: line ?? 1, project: root.path)
    }
}

// MARK: - Tree

struct FileNode: Identifiable, Hashable {
    let path: String
    let name: String
    var children: [FileNode]?
    var id: String { path }

    /// Folders first, then files, alphabetically; one node per path segment.
    static func tree(_ paths: [String]) -> [FileNode] {
        final class Box { var children: [String: Box] = [:]; var isFile = false }
        let root = Box()
        for path in paths {
            var node = root
            for part in path.split(separator: "/").map(String.init) {
                if node.children[part] == nil { node.children[part] = Box() }
                node = node.children[part]!
            }
            node.isFile = true
        }
        func build(_ box: Box, prefix: String) -> [FileNode] {
            box.children.map { name, child in
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                return FileNode(path: path, name: name, children: child.children.isEmpty ? nil : build(child, prefix: path))
            }
            .sorted { a, b in (a.children != nil) != (b.children != nil) ? a.children != nil : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        }
        return build(root, prefix: "")
    }
}

struct FileTreeView: View {
    let state: WorktreeState
    var onlyChanged: Bool

    var body: some View {
        let paths = onlyChanged ? state.diffs.map(\.path) : state.files
        let changedFolders = Set(state.diffs.flatMap { diff in
            var parts = diff.path.split(separator: "/").map(String.init).dropLast()
            var result: [String] = []
            while !parts.isEmpty { result.append(parts.joined(separator: "/")); parts.removeLast() }
            return result
        })
        List(selection: Binding(get: { state.selectedFile }, set: { if let path = $0 { state.reveal(path, line: state.diff(for: path)?.firstChange) } })) {
            OutlineGroup(FileNode.tree(paths), children: \.children) { node in
                HStack(spacing: 6) {
                    Image(systemName: node.children == nil ? "doc.text" : "folder").foregroundStyle(.secondary).frame(width: 14)
                    Text(node.name).lineLimit(1)
                    Spacer(minLength: 2)
                    if node.children == nil, let status = state.status(of: node.path) {
                        Text(Self.letter(status)).font(.caption.monospaced().bold()).foregroundStyle(Self.color(status))
                    } else if node.children != nil, changedFolders.contains(node.path) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                .tag(node.path)
                .contextMenu {
                    if node.children == nil {
                        Button("Open in \(Editor.preferred.name)") { state.open(node.path, line: state.diff(for: node.path)?.firstChange) }
                    }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.root.appending(path: node.path)]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.path, forType: .string)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    static func letter(_ status: FileDiff.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    static func color(_ status: FileDiff.Status) -> Color {
        switch status {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        }
    }
}

// MARK: - Changes

struct ChangesView: View {
    let state: WorktreeState
    /// A line was clicked: show it in the tree and the file.
    let onSelect: (String, Int) -> Void

    var body: some View {
        if state.diffs.isEmpty {
            ContentUnavailableView(state.loading ? "Loading…" : "No changes yet", systemImage: "plusminus",
                                   description: Text("Changes against \(state.base) show here as the agent works."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("\(state.diffs.count) files · +\(state.diffs.map(\.additions).reduce(0, +)) −\(state.diffs.map(\.deletions).reduce(0, +)) against \(state.base)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(state.diffs) { file in
                            fileSection(file).id(file.path)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: state.selectedFile) { if let path = state.selectedFile { withAnimation { proxy.scrollTo(path, anchor: .top) } } }
            }
        }
    }

    private func fileSection(_ file: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(FileTreeView.letter(file.status)).font(.caption.monospaced().bold()).foregroundStyle(FileTreeView.color(file.status))
                Button(file.path) { onSelect(file.path, file.firstChange) }.buttonStyle(.link).font(.callout.monospaced())
                if let old = file.oldPath { Text("← \(old)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                Text("+\(file.additions)").font(.caption.monospaced()).foregroundStyle(.green)
                Text("−\(file.deletions)").font(.caption.monospaced()).foregroundStyle(.red)
                Button("Open", systemImage: "arrow.up.forward.app") { state.open(file.path, line: file.firstChange) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help(Editor.preferred.command(file: file.path, line: file.firstChange, project: state.root.path))
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.06))
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line)
                        .contentShape(.rect)
                        .onTapGesture { onSelect(file.path, line.new ?? line.old ?? 1) }
                        .help("Show \(file.path):\(line.new ?? line.old ?? 1) in the tree and the file")
                }
            }
        }
        .background(.background)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

struct DiffLineView: View {
    let line: FileDiff.Line

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.new.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line.kind == .added ? " + " : line.kind == .removed ? " − " : "   ").foregroundStyle(color)
            Text(line.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption.monospaced())
        .padding(.vertical, 1)
        .background(color.opacity(line.kind == .context ? 0 : 0.12))
    }

    private var color: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .context: .primary
        }
    }
}

// MARK: - File

struct FileContentView: View {
    let state: WorktreeState
    let path: String
    @State private var lines: [String] = []

    var body: some View {
        let changed = state.diff(for: path)?.changedLines ?? []
        VStack(spacing: 0) {
            HStack {
                Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                if let status = state.status(of: path) { Text(FileTreeView.letter(status)).font(.caption.bold()).foregroundStyle(FileTreeView.color(status)) }
                Spacer()
                Button("Open in \(Editor.preferred.name)", systemImage: "arrow.up.forward.app") { state.open(path, line: state.selectedLine) }
                    .help(Editor.preferred.command(file: path, line: state.selectedLine ?? 1, project: state.root.path))
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                            let number = index + 1
                            HStack(spacing: 8) {
                                Text("\(number)").frame(width: 44, alignment: .trailing).foregroundStyle(.tertiary)
                                Text(text.isEmpty ? " " : text).textSelection(.enabled)
                            }
                            .font(.caption.monospaced())
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(number == state.selectedLine ? Color.accentColor.opacity(0.25) : changed.contains(number) ? Color.green.opacity(0.12) : .clear)
                            .id(number)
                            .onTapGesture(count: 2) { state.open(path, line: number) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: state.selectedLine) { scroll(proxy) }
            }
        }
        .task(id: path) {
            let url = state.root.appending(path: path)
            lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "(deleted or not text)").components(separatedBy: "\n")
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let line = state.selectedLine else { return }
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(line, anchor: .center) } }
    }
}
