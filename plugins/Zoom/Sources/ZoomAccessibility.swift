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
            return ["Transcript", "Captions", "Live Transcript", "Full Transcript"].contains { title.localizedCaseInsensitiveContains($0) }
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
