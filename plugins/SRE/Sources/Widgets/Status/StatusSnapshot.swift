import DashKit
import Foundation

/// What the SRE Status widget shows: plain data, so previews and tests need no services.
struct StatusSnapshot: Sendable, Equatable {
    struct Report: Sendable, Equatable {
        var summary: String
        var at: Date
        /// The three most severe findings' titles, for the panel.
        var findings: [String]
        var critical: Bool
        /// Every finding in full, for the report sheet.
        var items: [AgentFinding] = []
    }

    var signals: Signals
    var lastReport: Report?

    enum Level: Sendable { case ok, degraded, down, unknown }

    var level: Level {
        if signals.sources.isEmpty { return .unknown }
        if signals.monitors.contains(where: { $0.level == .critical }) || signals.pods.contains(where: { $0.level == .critical }) { return .down }
        return signals.isQuiet ? .ok : .degraded
    }

    static let sample = StatusSnapshot(
        signals: Signals(
            monitors: [Signal(id: "1201", title: "api 5xx rate", detail: "Alert · service api · env prod", level: .critical, since: nil),
                       Signal(id: "1188", title: "checkout p95 latency", detail: "Warn · service checkout · env prod", level: .warning, since: nil),
                       Signal(id: "1093", title: "worker queue depth", detail: "Warn · service worker · env prod", level: .warning, since: nil)],
            pods: [Signal(id: "bill-eu/api-7d9f8-x2k", title: "Pod api-7d9f8-x2k", detail: "CrashLoopBackOff in bill-eu · 14 restarts · BackOff",
                          level: .critical, since: nil),
                   Signal(id: "bill-eu/api-7d9f8-q4m", title: "Pod api-7d9f8-q4m", detail: "CrashLoopBackOff in bill-eu · 9 restarts · BackOff",
                          level: .critical, since: nil),
                   Signal(id: "bill-us/worker-5c4b-mn3", title: "Pod worker-5c4b-mn3", detail: "Running in bill-us · 2 restarts · Unhealthy",
                          level: .warning, since: nil)],
            sources: ["datadog", "kubernetes"]),
        lastReport: Report(summary: "5xx on api started at 10:02 with v1.42 rolling out; the new pods crash-loop on a missing config key.",
                           at: .now.addingTimeInterval(-600), findings: ["Roll back api to v1.41", "Add FEATURE_FLAGS_URL to the api config map", "Checkout latency follows the api errors"], critical: true))
}

extension StatusSnapshot.Report {
    /// The report in Dash's note syntax: the summary as a callout, then one callout per finding in
    /// its severity's colour, with the target, the evidence and what to do.
    var markdown: String {
        ([summaryMarkdown] + (items.isEmpty ? [] : [Self.findingsHeading] + items.map(Self.markdown(for:)))).joined(separator: "\n\n")
    }

    static let findingsHeading = "## Findings"

    var summaryMarkdown: String { (["> [!summary] Summary"] + Self.quoted(summary)).joined(separator: "\n") }

    /// One finding as a callout; the sheet draws each on its own, with buttons to ask about it.
    /// A detail or suggestion written as one long paragraph is laid out (see `readable`).
    static func markdown(for finding: AgentFinding) -> String {
        var lines = ["> [!\(callout(finding.severity))] \(finding.title.replacingOccurrences(of: "\n", with: " "))"]
        if !finding.target.isEmpty { lines.append("> " + target(finding.target)) }
        let detail = readable(finding.detail)
        if !detail.isEmpty { lines += [">"] + quoted(detail) }
        let suggestion = finding.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (lead, steps) = steps(in: suggestion) {
            lines += [">", "> **What to do**", ">"] + (lead.isEmpty ? [] : quoted(lead) + [">"])
                + steps.enumerated().map { "> \($0.offset + 1). \($0.element)" }
        } else if suggestion.contains("\n") {
            lines += [">", "> **What to do**", ">"] + quoted(suggestion)
        } else if !suggestion.isEmpty {
            lines += [">", "> **What to do:** \(suggestion)"]
        }
        return lines.joined(separator: "\n")
    }

    /// The target in code, its parenthesized context (cluster, project) after it in plain text:
    /// "deployment ns/api (cluster, project)" → "`deployment ns/api` · cluster, project".
    static func target(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "`", with: "'")
        if flat.hasSuffix(")"), let open = flat.range(of: " (", options: .backwards), open.lowerBound > flat.startIndex {
            let context = flat[open.upperBound..<flat.index(before: flat.endIndex)]
            return "`\(flat[..<open.lowerBound])` · \(context)"
        }
        return "`\(flat)`"
    }

    /// A paragraph of three or more sentences becomes its first sentence (with the next when the
    /// first is a short tag like "S3 (down, dev only).") and a bulleted list of the rest. Text
    /// that already has lines (lists, code, paragraphs) is the agent's layout and stays.
    static func readable(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n") else { return text }
        var parts = sentences(text)
        guard parts.count >= 3 else { return text }
        var lead = parts.removeFirst()
        if lead.count <= 40 { lead = "**\(lead)** " + parts.removeFirst() }
        return ([lead, ""] + parts.map { "- " + $0 }).joined(separator: "\n")
    }

    /// Sentences: split after `.`, `!` or `?` followed by a space and a capital, digit or quote;
    /// never after abbreviations (e.g., i.e., vs.) or a lone letter.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character), index + 2 < characters.count, characters[index + 1] == " " else { continue }
            let next = characters[index + 2]
            guard next.isUppercase || next.isNumber || "\"“‘'(".contains(next) else { continue }
            let word = current.dropLast().split(separator: " ").last.map { $0.lowercased() } ?? ""
            if ["e.g", "i.e", "vs", "etc", "approx", "cf"].contains(word.trimmingCharacters(in: CharacterSet(charactersIn: "(")))
                || (word.count == 1 && word.first?.isLetter == true) { continue }
            result.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Steps written inline ("act now: 1) add X; 2) raise Y, and 3) …") as the text before them
    /// and each step; nil unless they run 1, 2, 3… with at least two.
    static func steps(in text: String) -> (String, [String])? {
        guard !text.contains("\n") else { return nil }
        let markers = text.matches(of: /(?:^|\s)\(?(\d{1,2})\)\s/)
        guard markers.count >= 2, markers.enumerated().allSatisfy({ Int($0.element.output.1) == $0.offset + 1 }) else { return nil }
        let lead = String(text[..<markers[0].range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let steps = markers.indices.map { index in
            let end = index + 1 < markers.count ? markers[index + 1].range.lowerBound : text.endIndex
            var step = String(text[markers[index].range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            for ending in [" and", " or", ";", ","] where step.hasSuffix(ending) {
                step = String(step.dropLast(ending.count)).trimmingCharacters(in: .whitespaces)
            }
            return step.prefix(1).uppercased() + step.dropFirst()
        }
        return (lead, steps)
    }

    private static func callout(_ severity: AgentFinding.Severity) -> String {
        switch severity {
        case .critical: "danger"
        case .warning: "warning"
        default: "note"
        }
    }

    /// Every line inside the callout, blank ones included, so lists and code blocks stay in it.
    private static func quoted(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
    }
}
