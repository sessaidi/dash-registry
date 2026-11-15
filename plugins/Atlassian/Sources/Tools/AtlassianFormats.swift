import DashKit
import Foundation

/// Confluence storage format and Jira's Atlassian Document Format, turned into text Claude reads well.
enum AtlassianFormats {
    // MARK: Confluence storage → Markdown

    /// Confluence storage (XHTML with `ac:`/`ri:` macros) to Markdown: headings, paragraphs,
    /// emphasis, code, links, lists, tables and code macros. Anything else keeps its text.
    static func markdown(fromStorage html: String) -> String {
        var text = html
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        func replaceEach(_ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            let source = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                result += transform(match, source)
                last = match.range.location + match.range.length
            }
            result += source.substring(from: last)
            text = result
        }

        // Code keeps its body verbatim: set aside until the tags are gone.
        var blocks: [String] = []
        func keep(_ block: String) -> String {
            blocks.append(block)
            return "\u{1}\(blocks.count - 1)\u{1}"
        }
        replaceEach(#"<ac:structured-macro[^>]*ac:name="code"[^>]*>.*?(?:<ac:parameter ac:name="language">([^<]*)</ac:parameter>)?.*?<ac:plain-text-body><!\[CDATA\[(.*?)\]\]></ac:plain-text-body>.*?</ac:structured-macro>"#) { match, source in
            let language = match.range(at: 1).location == NSNotFound ? "" : source.substring(with: match.range(at: 1))
            return "\n" + keep("```\(language)\n\(source.substring(with: match.range(at: 2)))\n```") + "\n"
        }
        // Info/note/warning panels become quotes.
        replaceEach(#"<ac:structured-macro[^>]*ac:name="(info|note|warning|tip)"[^>]*>.*?<ac:rich-text-body>(.*?)</ac:rich-text-body>.*?</ac:structured-macro>"#) { match, source in
            "\n> **\(source.substring(with: match.range(at: 1)).capitalized):** \(source.substring(with: match.range(at: 2)))\n"
        }
        // Links to other pages and attachments: their title.
        replaceEach(#"<ac:link[^>]*>.*?<ri:page[^>]*ri:content-title="([^"]*)"[^>]*/>.*?</ac:link>"#) { match, source in
            "[[\(source.substring(with: match.range(at: 1)))]]"
        }
        replaceEach(#"<ac:image[^>]*>.*?<ri:attachment[^>]*ri:filename="([^"]*)"[^>]*/>.*?</ac:image>"#) { match, source in
            "[image: \(source.substring(with: match.range(at: 1)))]"
        }
        replace(#"<ac:[^>]*/>|</?ac:[^>]*>|</?ri:[^>]*>"#, "")

        replaceEach(#"<pre[^>]*>(.*?)</pre>"#) { match, source in
            "\n" + keep("```\n" + decodeEntities(stripTags(source.substring(with: match.range(at: 1)))) + "\n```") + "\n"
        }
        replaceEach(#"<h([1-6])[^>]*>(.*?)</h\1>"#) { match, source in
            "\n\n" + String(repeating: "#", count: Int(source.substring(with: match.range(at: 1))) ?? 1) + " " + source.substring(with: match.range(at: 2)) + "\n\n"
        }
        replaceEach(#"<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>"#) { match, source in
            "[\(source.substring(with: match.range(at: 2)))](\(source.substring(with: match.range(at: 1))))"
        }
        replace(#"<(strong|b)>(.*?)</\1>"#, "**$2**")
        replace(#"<(em|i)>(.*?)</\1>"#, "_$2_")
        replace(#"<code>(.*?)</code>"#, "`$1`")

        // Tables: one Markdown row per <tr>, a separator after the first.
        replaceEach(#"<table[^>]*>(.*?)</table>"#) { match, source in
            let body = source.substring(with: match.range(at: 1))
            guard let rowRegex = try? NSRegularExpression(pattern: #"<tr[^>]*>(.*?)</tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let cellRegex = try? NSRegularExpression(pattern: #"<t[hd][^>]*>(.*?)</t[hd]>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return body }
            let rows = rowRegex.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)).map { row -> [String] in
                let rowText = (body as NSString).substring(with: row.range(at: 1))
                return cellRegex.matches(in: rowText, range: NSRange(location: 0, length: (rowText as NSString).length)).map { cell in
                    stripTags((rowText as NSString).substring(with: cell.range(at: 1))).replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "|", with: "\\|").trimmingCharacters(in: .whitespaces)
                }
            }
            guard let first = rows.first else { return "" }
            var lines = ["| " + first.joined(separator: " | ") + " |", "|" + String(repeating: " --- |", count: first.count)]
            lines += rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
            return "\n\n" + lines.joined(separator: "\n") + "\n\n"
        }

        // Lists: ordered items numbered "1.", unordered "-", nesting indented.
        var output = ""
        var stack: [Bool] = []
        let tokens = try? NSRegularExpression(pattern: #"<(/?)(ul|ol|li)[^>]*>"#, options: [.caseInsensitive])
        let source = text as NSString
        var last = 0
        for match in tokens?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? [] {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let closing = !source.substring(with: match.range(at: 1)).isEmpty
            let tag = source.substring(with: match.range(at: 2)).lowercased()
            switch (tag, closing) {
            case ("ul", false): stack.append(false); output += "\n"
            case ("ol", false): stack.append(true); output += "\n"
            case ("ul", true), ("ol", true): _ = stack.popLast(); output += "\n"
            case ("li", false): output += "\n" + String(repeating: "  ", count: max(stack.count - 1, 0)) + (stack.last == true ? "1. " : "- ")
            default: break
            }
        }
        output += source.substring(from: last)
        text = output

        replace(#"<br ?/?>"#, "\n")
        replace(#"</p>|</div>|</blockquote>"#, "\n\n")
        text = stripTags(text)
        text = decodeEntities(text)
        // Paragraph tags inside list items leave blank lines between items.
        text = text.replacingOccurrences(of: #"\n\s*\n(\s*(?:- |1\. ))"#, with: "\n$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        for (index, block) in blocks.enumerated() { text = text.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: block) }
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        var text = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
                                    ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&ndash;", "–"), ("&mdash;", "—"),
                                    ("&hellip;", "…"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    // MARK: Jira ADF → text

    /// Atlassian Document Format (Jira descriptions and comments) to Markdown-ish text.
    static func text(fromADF node: JSONValue?) -> String {
        guard let node else { return "" }
        if let string = node.string { return string }
        var output = ""
        render(node, into: &output, depth: 0, ordered: nil)
        return output.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ node: JSONValue, into output: inout String, depth: Int, ordered: Bool?) {
        let children = node["content"]?.array ?? []
        func renderChildren(depth: Int = depth, ordered: Bool? = ordered) {
            for child in children { render(child, into: &output, depth: depth, ordered: ordered) }
        }
        switch node["type"]?.string ?? "" {
        case "text":
            var text = node["text"]?.string ?? ""
            for mark in node["marks"]?.array ?? [] {
                switch mark["type"]?.string {
                case "strong": text = "**\(text)**"
                case "em": text = "_\(text)_"
                case "code": text = "`\(text)`"
                case "link": if let href = mark["attrs"]?["href"]?.string { text = "[\(text)](\(href))" }
                default: break
                }
            }
            output += text
        case "hardBreak": output += "\n"
        case "paragraph": renderChildren(); output += "\n\n"
        case "heading":
            output += String(repeating: "#", count: node["attrs"]?["level"]?.int ?? 1) + " "
            renderChildren()
            output += "\n\n"
        case "bulletList": renderChildren(depth: depth + 1, ordered: false); output += "\n"
        case "orderedList": renderChildren(depth: depth + 1, ordered: true); output += "\n"
        case "listItem":
            output += String(repeating: "  ", count: max(depth - 1, 0)) + (ordered == true ? "1. " : "- ")
            var item = ""
            for child in children { render(child, into: &item, depth: depth, ordered: ordered) }
            output += item.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        case "codeBlock":
            output += "```\(node["attrs"]?["language"]?.string ?? "")\n"
            renderChildren()
            output += "\n```\n\n"
        case "blockquote", "panel":
            var inner = ""
            for child in children { render(child, into: &inner, depth: depth, ordered: ordered) }
            output += inner.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "mention": output += "@" + (node["attrs"]?["text"]?.string ?? "someone").trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        case "emoji": output += node["attrs"]?["text"]?.string ?? node["attrs"]?["shortName"]?.string ?? ""
        case "inlineCard", "blockCard": output += node["attrs"]?["url"]?.string ?? ""
        case "rule": output += "\n---\n\n"
        case "table":
            for row in children {
                let cells = (row["content"]?.array ?? []).map { cell -> String in
                    var text = ""
                    render(cell.merging(["type": "doc"]), into: &text, depth: depth, ordered: nil)
                    return text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                }
                output += "| " + cells.joined(separator: " | ") + " |\n"
            }
            output += "\n"
        default: renderChildren()
        }
    }
}
