import DashKit
import DashKitUI
import SwiftUI

extension ReleaseTimelineView {
    /// The picked release as a `releases` dataset row, for linked widgets.
    var pickedRow: JSONValue? {
        guard let picked else { return nil }
        for timeline in timelines where timeline.repository.id == picked.repository || timeline.releases.contains(where: { $0.id == picked.release }) {
            if let release = timeline.releases.first(where: { $0.id == picked.release }) {
                return release.queryRow(repository: timeline.repository.name)
            }
        }
        return nil
    }

    /// What the widget shows right now, for Dashii.
    var uiState: JSONValue {
        guard !timelines.isEmpty else { return ["state": feature.repositories.isEmpty ? "no repository" : "loading"] }
        let model = currentModel
        let now = feature.now()
        let shown = domain ?? initialDomain(fullDomain(model, now: now), now: now)
        let selected = selection.flatMap { selection in model.releases.first { $0.id == selection.release } }
        return [
            "repositories": .array(repositories.map { .string($0.name) }),
            "train": self.shown.train.map { .string($0.isEmpty ? "shared" : $0) } ?? "all",
            "visible_from": .string(ReleaseTimelineActions.day(shown.lowerBound)),
            "visible_to": .string(ReleaseTimelineActions.day(shown.upperBound)),
            "zoomed": .bool(domain != nil),
            "search": searching ? .string(query) : .null,
            "search_date": focusDate.map { .string(ReleaseTimelineActions.day($0)) } ?? .null,
            "highlighted_release": focused(model).map { .string($0.name) } ?? .null,
            "open_release": selected.map { .string($0.name) } ?? .null,
            "selected": pickedRow?["name"] ?? .null,
            "temporary_changes": .bool(override != nil),
            "live_now": .array(liveNow(now).map { .string("\($0.train): \($0.tag)") }),
        ]
    }

    /// Runs one of `ReleaseTimelineWidget.actions`.
    func perform(_ name: String, _ input: JSONValue) throws -> JSONValue {
        let model = currentModel
        let now = feature.now()
        switch name {
        case "search":
            guard let text = input["text"]?.string, !text.isEmpty else { throw ToolError("Give the text, ticket or date to search.") }
            searching = true
            query = text
            revealMatches(model, now: now)
            if let date = ReleaseDates.search(text, now: now) {
                let live = model.releases.first { $0.start <= date && date < $0.end }
                return ["date": .string(ReleaseTimelineActions.day(date)), "live_release": live.map { .string($0.name) } ?? .null]
            }
            return ["matches": .array(model.releases.filter { $0.matches(text) }.prefix(20).map { .string($0.name) })]
        case "select_release":
            guard let wanted = input["name"]?.string, let release = ReleaseTimelineActions.find(wanted, in: model.releases) else {
                throw ToolError("No release matching “\(input["name"]?.string ?? "")” in this widget.")
            }
            selection = ReleaseSelection(repository: release.repository, release: release.id)
            picked = selection
            return ["opened": .string(release.name)]
        case "set_train":
            let train = ReleaseTimelineActions.train(input["train"]?.string)
            let known = Set(timelines.flatMap(\.trains))
            if let train, !known.contains(train) {
                throw ToolError("No train “\(train)”. Trains: \(known.sorted().map { $0.isEmpty ? "shared" : $0 }.joined(separator: ", ")).")
            }
            var view = shown
            view.train = train
            override = view
            return ["train": train.map { .string($0.isEmpty ? "shared" : $0) } ?? "all"]
        case "set_period":
            let days = input["days"]?.int
            var view = shown
            view.period = days
            override = view
            domain = nil
            return ["period_days": days.map { .number(Double($0)) } ?? "all"]
        case "zoom":
            guard let from = input["from"]?.string.flatMap({ ReleaseDates.search($0, now: now) }),
                  let to = input["to"]?.string.flatMap({ ReleaseDates.search($0, now: now) }), from < to else {
                throw ToolError("Give from and to dates (2026-10-01, 12 Oct, W41), from before to.")
            }
            domain = from...to
            return ["visible_from": .string(ReleaseTimelineActions.day(from)), "visible_to": .string(ReleaseTimelineActions.day(to))]
        case "clear_selection":
            picked = nil
            return "cleared"
        case "clear":
            searching = false
            query = ""
            focusDate = nil
            domain = nil
            selection = nil
            override = nil
            return "cleared"
        default:
            throw ToolError("Unknown action \(name).")
        }
    }
}

/// The pure parts of the timeline's actions.
enum ReleaseTimelineActions {
    static func day(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

    /// "all" or nothing is every train; "shared" (or "") the shared one; else the suffix, lowercased.
    static func train(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), text != "all" else { return nil }
        return text == "shared" ? "" : text
    }

    /// A release by its name, short name or a tag of one of its builds; else the only one containing the text.
    static func find(_ text: String, in releases: [Release]) -> Release? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = releases.first(where: { $0.name.lowercased() == wanted || $0.shortName.lowercased() == wanted
            || $0.builds.contains { $0.tag.lowercased() == wanted } }) {
            return exact
        }
        let partial = releases.filter { $0.name.lowercased().contains(wanted) }
        return partial.count == 1 ? partial[0] : partial.last
    }
}

struct ReleaseSelection: Identifiable, Hashable {
    var id: String { release }
    let repository: String
    var release: String
}
