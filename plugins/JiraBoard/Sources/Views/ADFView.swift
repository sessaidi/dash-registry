import DashKit
import SwiftUI

/// Atlassian Document Format drawn as Jira draws it: headings, paragraphs with bold, italic,
/// code, strike and links, nested bullet and numbered lists, code blocks, quotes, panels, tables,
/// expands and rules. Unknown nodes fall back to their children, so nothing is lost.
struct ADFView: View {
    let document: JSONValue

    var body: some View {
        let blocks = document["content"]?.array ?? []
        if blocks.isEmpty, let text = document.string, !text.isEmpty {
            Text(text).textSelection(.enabled)
        } else if blocks.isEmpty {
            Text("No description.").foregroundStyle(.secondary)
        } else {
            ADFBlocks(nodes: blocks)
        }
    }

    /// The inline nodes of a block as styled text. `site` is the Jira site's host: its issue
    /// links show as their key.
    static func inline(_ nodes: [JSONValue], site: String? = nil) -> AttributedString {
        var result = AttributedString()
        for node in nodes {
            switch node["type"]?.string {
            case "text":
                var piece = AttributedString(node["text"]?.string ?? "")
                var intent: InlinePresentationIntent = []
                for mark in node["marks"]?.array ?? [] {
                    switch mark["type"]?.string {
                    case "strong": intent.insert(.stronglyEmphasized)
                    case "em": intent.insert(.emphasized)
                    case "code":
                        intent.insert(.code)
                        piece.backgroundColor = Color.secondary.opacity(0.15)
                    case "strike": intent.insert(.strikethrough)
                    case "underline": piece.underlineStyle = .single
                    case "link":
                        if let url = Self.safeLink(mark["attrs"]?["href"]?.string) { piece.link = url }
                    default: break
                    }
                }
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                result += piece
            case "hardBreak":
                result += AttributedString("\n")
            case "mention":
                var piece = AttributedString(node["attrs"]?["text"]?.string ?? "@someone")
                piece.foregroundColor = .accentColor
                result += piece
            case "emoji":
                result += AttributedString(node["attrs"]?["text"]?.string ?? node["attrs"]?["shortName"]?.string ?? "")
            case "inlineCard", "blockCard", "embedCard":
                let href = node["attrs"]?["url"]?.string ?? ""
                var piece = AttributedString(Self.shortLink(href, site: site))
                if let url = Self.safeLink(href) { piece.link = url }
                result += piece
            case "status":
                var piece = AttributedString(" \(node["attrs"]?["text"]?.string?.uppercased() ?? "") ")
                piece.font = .caption.bold()
                piece.backgroundColor = Color.secondary.opacity(0.2)
                result += piece
            case "date":
                if let milliseconds = node["attrs"]?["timestamp"]?.string.flatMap(Double.init) {
                    result += AttributedString(Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .omitted))
                }
            default:
                result += inline(node["content"]?.array ?? [], site: site)
            }
        }
        return result
    }

    /// A Jira or web link as its issue key or host and path. Only links to the user's own site
    /// show as a bare key: anyone can write a comment, and "KAN-1" must not hide another site.
    static func shortLink(_ href: String, site: String?) -> String {
        guard let url = URL(string: href) else { return href }
        let host = url.host() ?? ""
        if let site, host.caseInsensitiveCompare(site) == .orderedSame, let range = url.path.range(of: "/browse/") {
            return String(url.path[range.upperBound...])
        }
        return host + url.path
    }

    /// A link from a document, clickable only for the web and mail: documents are written by
    /// anyone on the site, and `file:` or app URLs shouldn't be one click away.
    static func safeLink(_ href: String?) -> URL? {
        guard let href, let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}

struct ADFBlocks: View {
    let nodes: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { ADFBlock(node: $0.element) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// The Jira site's host, for documents drawn below (its issue links show as keys).
    @Entry var jiraSite: String?
}

private struct ADFBlock: View {
    let node: JSONValue
    @Environment(\.jiraSite) private var site
    private var children: [JSONValue] { node["content"]?.array ?? [] }

    var body: some View {
        switch node["type"]?.string {
        case "paragraph":
            if !children.isEmpty { Text(ADFView.inline(children, site: site)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        case "heading":
            let level = node["attrs"]?["level"]?.int ?? 2
            Text(ADFView.inline(children, site: site))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .textSelection(.enabled)
        case "bulletList", "orderedList":
            let ordered = node["type"]?.string == "orderedList"
            let start = node["attrs"]?["order"]?.int ?? 1
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + index)." : "•").foregroundStyle(.secondary).monospacedDigit()
                        ADFBlocks(nodes: item["content"]?.array ?? [])
                    }
                }
            }
            .padding(.leading, 6)
        case "taskList", "decisionList":
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, item in
                    let done = item["attrs"]?["state"]?.string == "DONE" || item["attrs"]?["state"]?.string == "DECIDED"
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item["type"]?.string == "decisionItem" ? "arrow.triangle.branch" : done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done ? Color.green : Color.secondary)
                        Text(ADFView.inline(item["content"]?.array ?? [], site: site)).textSelection(.enabled)
                    }
                }
            }
        case "codeBlock":
            ScrollView(.horizontal) {
                Text(children.compactMap { $0["text"]?.string }.joined())
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
        case "blockquote":
            HStack(spacing: 10) {
                Rectangle().fill(.tertiary).frame(width: 3)
                ADFBlocks(nodes: children).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case "panel":
            let style = Self.panel(node["attrs"]?["panelType"]?.string)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.icon).foregroundStyle(style.color)
                ADFBlocks(nodes: children)
            }
            .padding(10)
            .background(style.color.opacity(0.12), in: .rect(cornerRadius: 6))
        case "rule":
            Divider()
        case "table":
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array((row["content"]?.array ?? []).enumerated()), id: \.offset) { _, cell in
                            ADFBlocks(nodes: cell["content"]?.array ?? [])
                                .font(cell["type"]?.string == "tableHeader" ? .body.bold() : .body)
                                .padding(6)
                                .background(cell["type"]?.string == "tableHeader" ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.clear))
                                .border(.separator, width: 0.5)
                        }
                    }
                }
            }
        case "expand", "nestedExpand":
            DisclosureGroup(node["attrs"]?["title"]?.string ?? "Details") { ADFBlocks(nodes: children).padding(.top, 4) }
        case "mediaSingle", "mediaGroup", "media":
            Label("Attachment (open in Jira to view)", systemImage: "paperclip").font(.callout).foregroundStyle(.secondary)
        case "blockCard", "embedCard":
            Text(ADFView.inline([node], site: site))
        default:
            if children.contains(where: { ["text", "hardBreak", "mention", "emoji", "inlineCard"].contains($0["type"]?.string ?? "") }) {
                Text(ADFView.inline(children, site: site)).textSelection(.enabled)
            } else if !children.isEmpty {
                ADFBlocks(nodes: children)
            }
        }
    }

    private static func panel(_ type: String?) -> (icon: String, color: Color) {
        switch type {
        case "warning": ("exclamationmark.triangle.fill", .orange)
        case "error": ("xmark.octagon.fill", .red)
        case "success": ("checkmark.circle.fill", .green)
        case "note": ("note.text", .purple)
        default: ("info.circle.fill", .blue)
        }
    }
}
