import DashKit
import Foundation

/// A YAML subset parser, enough for kubeconfig files and similar configuration:
/// block mappings and sequences (including `key:` followed by a sequence at the same
/// indentation, as kubectl writes them), plain / single-quoted / double-quoted scalars,
/// one-line flow collections (`[]`, `{}`, `[a, b]`, `{k: v}`), literal and folded block
/// scalars (`|`, `>`, with `-`/`+` chomping), comments, and `---` document markers.
///
/// Not supported: anchors and aliases, tags, multi-line plain or flow scalars, complex keys,
/// multiple documents (only the first is read).
///
/// Plain scalars resolve like YAML 1.2's core schema, restricted to what configs need:
/// `null`/`~`/empty → null, `true`/`false` → bool, integers → number; everything else stays a string.
enum YAML {
    struct ParseError: LocalizedError, Equatable {
        let line: Int
        let message: String
        var errorDescription: String? { "YAML line \(line): \(message)" }
    }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }
}

extension JSONValue {
    /// A scalar as text, whatever YAML resolved it to (numbers without a decimal point).
    var scalarText: String? {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        default: nil
        }
    }

    /// YAML truthiness for flags such as `insecure-skip-tls-verify`.
    var flag: Bool {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "yes", "on"].contains(value.lowercased())
        default: false
        }
    }
}

private struct Parser {
    struct Line {
        let number: Int
        /// The line without its line break.
        let raw: String
        var indent: Int
        /// Text after the indentation, comment removed, trailing spaces trimmed.
        var content: String
        var isBlank: Bool { content.isEmpty }
    }

    var lines: [Line] = []
    var index = 0

    init(text: String) {
        var number = 0
        // "\r\n" is a single Character in Swift, so normalize line breaks before splitting.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        for rawSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            var raw = String(rawSub)
            if raw.hasSuffix("\r") { raw.removeLast() }
            if number == 1, raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
            let indent = raw.prefix { $0 == " " }.count
            let body = String(raw.dropFirst(indent))
            lines.append(Line(number: number, raw: raw, indent: indent, content: Self.stripComment(body)))
        }
    }

    // MARK: Lines

    var current: Line? { index < lines.count ? lines[index] : nil }

    mutating func skipBlank() {
        while let line = current, line.isBlank { index += 1 }
    }

    /// Removes a `#` comment (at the start, or after whitespace) that isn't inside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character?
        var lastSignificant: Character?
        var escaped = false
        var result = ""
        for char in text {
            if let open = quote {
                if open == "\"" {
                    if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { quote = nil }
                } else if char == "'" {
                    quote = nil  // '' inside a single-quoted scalar closes and reopens: same effect.
                }
            } else if char == "#", previous == nil || previous == " " || previous == "\t" {
                break
            } else if char == "\"" || char == "'" {
                // A quote opens a scalar only where one can start.
                if lastSignificant == nil || [":", "-", "[", "{", ",", "?"].contains(lastSignificant!) { quote = char }
            }
            result.append(char)
            previous = char
            if char != " " && char != "\t" { lastSignificant = char }
        }
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    static func isSequenceItem(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
    }

    // MARK: Document

    mutating func parseDocument() throws -> JSONValue {
        // Directives and the document start marker.
        while let line = current {
            if line.isBlank || (line.indent == 0 && line.content.hasPrefix("%")) {
                index += 1
            } else if line.indent == 0, line.content == "---" {
                index += 1
            } else if line.indent == 0, line.content.hasPrefix("--- ") {
                // "--- value" on the marker line.
                lines[index].content = String(line.content.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                lines[index].indent = 4
                break
            } else {
                break
            }
        }
        if let tab = lines[index...].first(where: { $0.raw.prefix { $0 == " " }.count < $0.raw.count && $0.raw.dropFirst($0.indent).hasPrefix("\t") && !$0.isBlank }) {
            throw YAML.ParseError(line: tab.number, message: "tabs are not allowed for indentation")
        }
        let value = try parseNode(minIndent: 0)
        skipBlank()
        if let line = current, !(line.indent == 0 && (line.content == "---" || line.content == "...")) {
            throw YAML.ParseError(line: line.number, message: "unexpected content \"\(line.content)\"")
        }
        return value
    }

    /// The node starting at the next non-blank line, if it is indented at least `minIndent`.
    mutating func parseNode(minIndent: Int) throws -> JSONValue {
        skipBlank()
        guard let line = current, line.indent >= minIndent else { return .null }
        if line.indent == 0, line.content == "---" || line.content == "..." { return .null }
        if Self.isSequenceItem(line.content) { return try parseSequence(indent: line.indent) }
        if try Self.splitKey(line.content, line: line.number) != nil { return try parseMapping(indent: line.indent) }
        index += 1
        if let header = BlockHeader(line.content) { return try parseBlockScalar(header, parentIndent: minIndent - 1) }
        return try inlineValue(line.content, line: line.number, parentIndent: minIndent - 1)
    }

    /// An inline value; a plain scalar may continue on following, more-indented lines
    /// (gcloud writes `installHint` that way). Continuation lines are joined with spaces.
    mutating func inlineValue(_ text: String, line: Int, parentIndent: Int) throws -> JSONValue {
        guard let first = text.first, !["\"", "'", "[", "{"].contains(first) else { return try Self.inlineValue(text, line: line) }
        var plain = text
        var continued = false
        while let next = current, !next.isBlank, next.indent > parentIndent, (try? Self.splitKey(next.content, line: next.number)) ?? nil == nil {
            plain += " " + next.content
            continued = true
            index += 1
        }
        return continued ? .string(plain) : try Self.inlineValue(text, line: line)
    }

    mutating func parseSequence(indent: Int) throws -> JSONValue {
        var items: [JSONValue] = []
        while true {
            skipBlank()
            guard let line = current, line.indent == indent, Self.isSequenceItem(line.content) else { break }
            let rest = line.content.dropFirst()
            let spaces = rest.prefix { $0 == " " || $0 == "\t" }.count
            let item = String(rest.dropFirst(spaces))
            if item.isEmpty {
                index += 1
                items.append(try parseNode(minIndent: indent + 1))
            } else {
                // Re-read the rest of the line as a node at its own column, so
                // "- name: a\n  value: b" becomes one mapping.
                lines[index].indent = indent + 1 + spaces
                lines[index].content = item
                items.append(try parseNode(minIndent: indent + 1))
            }
        }
        if let line = current, !line.isBlank, line.indent > indent {
            throw YAML.ParseError(line: line.number, message: "bad indentation of a sequence entry")
        }
        return .array(items)
    }

    mutating func parseMapping(indent: Int) throws -> JSONValue {
        var object: [String: JSONValue] = [:]
        while true {
            skipBlank()
            guard let line = current, line.indent == indent else { break }
            if line.indent == 0, line.content == "---" || line.content == "..." { break }
            if Self.isSequenceItem(line.content) {
                throw YAML.ParseError(line: line.number, message: "sequence entry where a mapping key was expected")
            }
            guard let (key, rest) = try Self.splitKey(line.content, line: line.number) else {
                throw YAML.ParseError(line: line.number, message: "expected \"key: value\", found \"\(line.content)\"")
            }
            index += 1
            let value: JSONValue
            if rest.isEmpty {
                skipBlank()
                if let next = current, next.indent > indent {
                    value = try parseNode(minIndent: indent + 1)
                } else if let next = current, next.indent == indent, Self.isSequenceItem(next.content) {
                    value = try parseSequence(indent: indent)
                } else {
                    value = .null
                }
            } else if let header = BlockHeader(rest) {
                value = try parseBlockScalar(header, parentIndent: indent)
            } else {
                value = try inlineValue(rest, line: line.number, parentIndent: indent)
            }
            object[key] = value
        }
        if let line = current, !line.isBlank, line.indent > indent {
            throw YAML.ParseError(line: line.number, message: "bad indentation of a mapping entry")
        }
        return .object(object)
    }

    /// "key: rest" → (key, rest); nil when the line isn't a mapping entry.
    static func splitKey(_ content: String, line: Int) throws -> (String, String)? {
        guard let first = content.first, first != "[", first != "{" else { return nil }
        let chars = Array(content)
        var keyEnd: Int
        var key: String
        if first == "\"" || first == "'" {
            guard let (scalar, end) = try quoted(chars, from: 0, line: line) else { return nil }
            var cursor = end
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            guard cursor < chars.count, chars[cursor] == ":", cursor + 1 == chars.count || chars[cursor + 1] == " " || chars[cursor + 1] == "\t" else { return nil }
            key = scalar
            keyEnd = cursor
        } else {
            var cursor = 0
            var found: Int?
            while cursor < chars.count {
                if chars[cursor] == ":", cursor + 1 == chars.count || chars[cursor + 1] == " " || chars[cursor + 1] == "\t" {
                    found = cursor
                    break
                }
                cursor += 1
            }
            guard let found else { return nil }
            key = String(chars[0..<found]).trimmingCharacters(in: .whitespaces)
            keyEnd = found
            if key.hasPrefix("? ") || key.hasPrefix("&") || key.hasPrefix("*") || key.hasPrefix("!") {
                throw YAML.ParseError(line: line, message: "complex keys, anchors, aliases and tags are not supported")
            }
        }
        let rest = String(chars[(keyEnd + 1)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    // MARK: Scalars

    struct BlockHeader {
        let folded: Bool
        /// "-" strip, "+" keep, nil clip.
        let chomping: Character?
        let explicitIndent: Int?

        init?(_ text: String) {
            guard let first = text.first, first == "|" || first == ">" else { return nil }
            folded = first == ">"
            var chomping: Character?
            var indent: Int?
            for char in text.dropFirst() {
                if char == "-" || char == "+" { chomping = char } else if let digit = char.wholeNumberValue, digit > 0 { indent = digit } else { return nil }
            }
            self.chomping = chomping
            explicitIndent = indent
        }
    }

    mutating func parseBlockScalar(_ header: BlockHeader, parentIndent: Int) throws -> JSONValue {
        // Block content is raw text: comments and quotes mean nothing inside it.
        var blockIndent = header.explicitIndent.map { max(parentIndent, 0) + $0 }
        var collected: [String] = []
        while let line = current {
            let isBlank = line.raw.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                collected.append("")
                index += 1
                continue
            }
            if blockIndent == nil {
                guard line.indent > parentIndent else { break }
                blockIndent = line.indent
            }
            guard line.indent >= blockIndent! else { break }
            collected.append(String(line.raw.dropFirst(blockIndent!)))
            index += 1
        }
        // Trailing blank lines belong to chomping, and may have been the next node's leading blanks.
        var trailing = 0
        while let last = collected.last, last.isEmpty {
            collected.removeLast()
            trailing += 1
        }
        var text: String
        if header.folded {
            text = ""
            var previousWasText = false
            for (offset, line) in collected.enumerated() {
                if line.isEmpty {
                    text += "\n"
                    previousWasText = false
                } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    // More-indented lines keep their line breaks.
                    if offset > 0, previousWasText { text += "\n" }
                    text += line
                    previousWasText = false
                    if offset + 1 < collected.count { text += "\n" }
                } else {
                    if previousWasText { text += " " }
                    text += line
                    previousWasText = true
                }
            }
        } else {
            text = collected.joined(separator: "\n")
        }
        switch header.chomping {
        case "-": break
        case "+": text += String(repeating: "\n", count: collected.isEmpty ? trailing : trailing + 1)
        default: if !collected.isEmpty { text += "\n" }
        }
        return .string(text)
    }

    /// A scalar or one-line flow collection that fills the rest of a line.
    static func inlineValue(_ text: String, line: Int) throws -> JSONValue {
        let chars = Array(text)
        var cursor = 0
        let value = try flowValue(chars, &cursor, line: line, inFlow: false)
        while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
        guard cursor == chars.count else {
            throw YAML.ParseError(line: line, message: "unexpected text after value: \"\(String(chars[cursor...]))\"")
        }
        return value
    }

    static func flowValue(_ chars: [Character], _ cursor: inout Int, line: Int, inFlow: Bool) throws -> JSONValue {
        while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
        guard cursor < chars.count else { return .null }
        switch chars[cursor] {
        case "\"", "'":
            guard let (scalar, end) = try quoted(chars, from: cursor, line: line) else {
                throw YAML.ParseError(line: line, message: "unterminated quoted scalar (multi-line quoted scalars are not supported)")
            }
            cursor = end
            return .string(scalar)
        case "[":
            cursor += 1
            var items: [JSONValue] = []
            while true {
                skipSpaces(chars, &cursor)
                guard cursor < chars.count else { throw YAML.ParseError(line: line, message: "unterminated flow sequence") }
                if chars[cursor] == "]" { cursor += 1; break }
                items.append(try flowValue(chars, &cursor, line: line, inFlow: true))
                skipSpaces(chars, &cursor)
                guard cursor < chars.count else { throw YAML.ParseError(line: line, message: "unterminated flow sequence") }
                if chars[cursor] == "," { cursor += 1 } else if chars[cursor] != "]" {
                    throw YAML.ParseError(line: line, message: "expected , or ] in flow sequence")
                }
            }
            return .array(items)
        case "{":
            cursor += 1
            var object: [String: JSONValue] = [:]
            while true {
                skipSpaces(chars, &cursor)
                guard cursor < chars.count else { throw YAML.ParseError(line: line, message: "unterminated flow mapping") }
                if chars[cursor] == "}" { cursor += 1; break }
                let keyValue = try flowValue(chars, &cursor, line: line, inFlow: true)
                guard let key = keyValue.scalarText ?? (keyValue == .null ? "" : nil) else {
                    throw YAML.ParseError(line: line, message: "flow mapping keys must be scalars")
                }
                skipSpaces(chars, &cursor)
                var value = JSONValue.null
                if cursor < chars.count, chars[cursor] == ":" {
                    cursor += 1
                    value = try flowValue(chars, &cursor, line: line, inFlow: true)
                    skipSpaces(chars, &cursor)
                }
                object[key] = value
                guard cursor < chars.count else { throw YAML.ParseError(line: line, message: "unterminated flow mapping") }
                if chars[cursor] == "," { cursor += 1 } else if chars[cursor] != "}" {
                    throw YAML.ParseError(line: line, message: "expected , or } in flow mapping")
                }
            }
            return .object(object)
        case "&", "*", "!":
            throw YAML.ParseError(line: line, message: "anchors, aliases and tags are not supported")
        default:
            let start = cursor
            while cursor < chars.count {
                let char = chars[cursor]
                if inFlow {
                    if char == "," || char == "]" || char == "}" { break }
                    if char == ":", cursor + 1 == chars.count || [" ", ",", "]", "}"].contains(chars[cursor + 1]) { break }
                }
                cursor += 1
            }
            return resolve(String(chars[start..<cursor]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func skipSpaces(_ chars: [Character], _ cursor: inout Int) {
        while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" { cursor += 1 }
    }

    /// Parses a quoted scalar at `from`; returns its value and the index after the closing quote.
    static func quoted(_ chars: [Character], from: Int, line: Int) throws -> (String, Int)? {
        let open = chars[from]
        var result = ""
        var cursor = from + 1
        while cursor < chars.count {
            let char = chars[cursor]
            if open == "'" {
                if char == "'" {
                    if cursor + 1 < chars.count, chars[cursor + 1] == "'" {
                        result.append("'")
                        cursor += 2
                        continue
                    }
                    return (result, cursor + 1)
                }
                result.append(char)
                cursor += 1
            } else {
                if char == "\"" { return (result, cursor + 1) }
                if char == "\\" {
                    cursor += 1
                    guard cursor < chars.count else { return nil }
                    let escape = chars[cursor]
                    switch escape {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "0": result.append("\0")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case " ": result.append(" ")
                    case "x", "u", "U":
                        let width = escape == "x" ? 2 : escape == "u" ? 4 : 8
                        guard cursor + width < chars.count,
                              let code = UInt32(String(chars[(cursor + 1)...(cursor + width)]), radix: 16),
                              let scalar = Unicode.Scalar(code) else {
                            throw YAML.ParseError(line: line, message: "bad \\\(escape) escape")
                        }
                        result.unicodeScalars.append(scalar)
                        cursor += width
                    default:
                        throw YAML.ParseError(line: line, message: "unknown escape \\\(escape)")
                    }
                    cursor += 1
                    continue
                }
                result.append(char)
                cursor += 1
            }
        }
        return nil
    }

    static func resolve(_ plain: String) -> JSONValue {
        switch plain {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default:
            let digits = plain.hasPrefix("-") || plain.hasPrefix("+") ? plain.dropFirst() : Substring(plain)
            if !digits.isEmpty, digits.count < 16, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
               !(digits.count > 1 && digits.hasPrefix("0")), let number = Int64(plain) {
                return .number(Double(number))
            }
            return .string(plain)
        }
    }
}
