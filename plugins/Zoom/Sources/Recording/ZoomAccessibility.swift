import AppKit
import ApplicationServices
import DashKit

/// Reads Zoom's window titles and participant list through the Accessibility API.
/// Zoom's UI is not a stable interface, so every result here is best effort.
@MainActor
enum ZoomAccessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static var isZoomRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: MeetingRecorder.zoomBundleID).isEmpty
    }

    private static var zoom: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: MeetingRecorder.zoomBundleID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static var windows: [AXUIElement] {
        guard let zoom else { return [] }
        return (attribute(zoom, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// True while a Zoom meeting or webinar window is open.
    static var isInMeeting: Bool {
        windows.contains { isMeetingWindow(string($0, kAXTitleAttribute) ?? "") }
    }

    /// Titles of Zoom's meeting and webinar windows.
    nonisolated static func isMeetingWindow(_ title: String) -> Bool {
        title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar") || title == "Meeting"
    }

    /// Names in Zoom's Participants panel (open it, or pop it out, for this to work).
    static func participants() -> [String] {
        let panels = windows.filter { (string($0, kAXTitleAttribute) ?? "").hasPrefix("Participants") }
        let roots = panels.isEmpty ? windows : panels
        var names: [String] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int, inList: Bool) {
            visited += 1
            guard depth < 30, visited < 5000 else { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            if inList, role == kAXRowRole || role == kAXCellRole {
                if let name = firstText(element), !name.isEmpty { names.append(clean(name)) }
                return
            }
            let label = (string(element, kAXTitleAttribute) ?? "") + (string(element, kAXDescriptionAttribute) ?? "")
            let list = inList || !panels.isEmpty || label.localizedCaseInsensitiveContains("participant")
            for child in children(element) { walk(child, depth: depth + 1, inList: list && (role == kAXTableRole || role == kAXOutlineRole || role == kAXListRole || inList)) }
        }
        for root in roots { walk(root, depth: 0, inList: false) }
        return unique(names)
    }

    private static func firstText(_ element: AXUIElement, depth: Int = 0) -> String? {
        if (string(element, kAXRoleAttribute) ?? "") == kAXStaticTextRole, let value = string(element, kAXValueAttribute) { return value }
        if let description = string(element, kAXDescriptionAttribute), !description.isEmpty, depth > 0 { return description }
        guard depth < 6 else { return nil }
        for child in children(element) {
            if let text = firstText(child, depth: depth + 1) { return text }
        }
        return nil
    }

    /// Lines of Zoom's captions / transcript window ("Transcript", "Captions", "Live Transcript"),
    /// each with the participant's name. Zoom shows names only when captions or the live
    /// transcript are on; empty otherwise.
    static func captionLines() -> [(speaker: String, text: String)] {
        let panels = windows.filter { window in
            let title = string(window, kAXTitleAttribute) ?? ""
            return transcriptTitles.contains { title.localizedCaseInsensitiveContains($0) }
        }
        var lines: [(String, String)] = []
        var visited = 0
        func texts(_ element: AXUIElement, depth: Int, into out: inout [String]) {
            visited += 1
            guard depth < 12, visited < 8000 else { return }
            if (string(element, kAXRoleAttribute) ?? "") == kAXStaticTextRole, let value = string(element, kAXValueAttribute), !value.isEmpty { out.append(value) }
            for child in children(element) { texts(child, depth: depth + 1, into: &out) }
        }
        func walk(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 30, visited < 8000 else { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == kAXRowRole || role == kAXCellRole || role == kAXGroupRole && depth > 3 {
                var parts: [String] = []
                texts(element, depth: 0, into: &parts)
                if let line = captionLine(parts) { lines.append(line); return }
            }
            for child in children(element) { walk(child, depth: depth + 1) }
        }
        for panel in panels { walk(panel, depth: 0) }
        return lines
    }

    /// A row's texts as (name, text): ["Ada Lovelace", "10:02", "I finished the API"] or
    /// ["Ada Lovelace: I finished the API"].
    nonisolated static func captionLine(_ parts: [String]) -> (speaker: String, text: String)? {
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let isTime: (String) -> Bool = { $0.range(of: #"^\d{1,2}:\d{2}(:\d{2})?( ?[AP]M)?$"#, options: .regularExpression) != nil }
        let content = cleaned.filter { !isTime($0) }
        if content.count >= 2, content[0].count <= 60, !content[0].hasSuffix(".") {
            return (clean(content[0]), content.dropFirst().joined(separator: " "))
        }
        if content.count == 1, let colon = content[0].range(of: ": "), content[0].distance(from: content[0].startIndex, to: colon.lowerBound) <= 60 {
            return (clean(String(content[0][..<colon.lowerBound])), String(content[0][colon.upperBound...]))
        }
        return nil
    }

    // MARK: Transcript panel

    static let transcriptTitles = ["Transcript", "Captions", "Live Transcript", "Full Transcript"]

    /// A transcript or captions window is open.
    static var isTranscriptOpen: Bool {
        windows.contains { window in transcriptTitles.contains { (string(window, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains($0) } }
    }

    /// Presses the meeting window's transcript control ("View Full Transcript", else "Show
    /// Captions"): true when one was found and pressed. Zoom's controls aren't a stable interface,
    /// so this is best effort.
    @discardableResult
    static func openTranscript() -> Bool {
        let meetings = windows.filter { isMeetingWindow(string($0, kAXTitleAttribute) ?? "") }
        for wanted in [["full transcript", "view transcript", "show transcript"], ["show captions", "captions"]] {
            for window in meetings {
                if let control = find(in: window, matching: wanted), AXUIElementPerformAction(control, kAXPressAction as CFString) == .success { return true }
            }
        }
        return false
    }

    /// The first pressable element whose title, description or help matches one of `labels`.
    private static func find(in root: AXUIElement, matching labels: [String]) -> AXUIElement? {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            visited += 1
            guard depth < 30, visited < 5000 else { return nil }
            let role = string(element, kAXRoleAttribute) ?? ""
            if [kAXButtonRole, kAXMenuButtonRole, kAXMenuItemRole, kAXCheckBoxRole].contains(role) {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { string(element, $0) }.joined(separator: " ").lowercased()
                if labels.contains(where: { label.contains($0) }) { return element }
            }
            for child in children(element) { if let found = walk(child, depth: depth + 1) { return found } }
            return nil
        }
        return walk(root, depth: 0)
    }

    // MARK: Window structure

    /// Every Zoom window's accessibility tree as indented text (role, subrole, title,
    /// description, value, actions): what new readers of Zoom (active speaker, chat, joins and
    /// leaves) are built from. Values are cut at 200 characters.
    static func structure() -> String {
        guard let zoom else { return "Zoom isn't running." }
        var lines: [String] = []
        var visited = 0
        func describe(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 40, visited < 20000 else { return }
            var parts = [string(element, kAXRoleAttribute) ?? "?"]
            if let subrole = string(element, kAXSubroleAttribute) { parts.append("(\(subrole))") }
            for (key, name) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute), ("id", kAXIdentifierAttribute)] {
                if let value = string(element, name), !value.isEmpty { parts.append("\(key)=\"\(value.prefix(200))\"") }
            }
            if let value = attribute(element, kAXValueAttribute) {
                let text = (value as? String) ?? "\(value)"
                if !text.isEmpty { parts.append("value=\"\(text.prefix(200).replacingOccurrences(of: "\n", with: " "))\"") }
            }
            var names: CFArray?
            if AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String], !actions.isEmpty {
                parts.append("actions=" + actions.joined(separator: ","))
            }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            for child in children(element) { describe(child, depth: depth + 1) }
        }
        for window in (attribute(zoom, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { describe(window, depth: 0) }
        if let menu = attribute(zoom, kAXMenuBarAttribute) { lines.append("# Menu bar"); describe(menu as! AXUIElement, depth: 0) }
        return lines.joined(separator: "\n")
    }

    /// "Ada Lovelace (Host, me)" -> "Ada Lovelace"
    nonisolated static func clean(_ name: String) -> String {
        var result = name
        if let range = result.range(of: " (") { result = String(result[..<range.lowerBound]) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops repeated names, keeping the first of each.
    nonisolated static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
