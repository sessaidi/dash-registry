import DashKit
import Foundation

/// A monitor and its overall state, from monitor search.
struct DatadogMonitor: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let type: String
    let tags: [String]
    let lastTriggered: Date?

    static func list(_ search: JSONValue) -> [DatadogMonitor] {
        (search["monitors"]?.array ?? []).compactMap { item in
            guard let id = item["id"]?.int else { return nil }
            return DatadogMonitor(
                id: id, name: item["name"]?.string ?? "Monitor \(id)", status: item["status"]?.string ?? "Unknown",
                type: item["type"]?.string ?? "", tags: (item["tags"]?.array ?? []).compactMap(\.string),
                lastTriggered: item["last_triggered_ts"]?.double.map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Alert first, then Warn, No Data, then the rest.
    var severity: Int {
        switch status.lowercased() {
        case "alert": 0
        case "warn": 1
        case "no data": 2
        case "ok": 4
        default: 3
        }
    }

    var json: JSONValue {
        ["id": .number(Double(id)), "name": .string(name), "status": .string(status), "type": .string(type),
         "tags": .array(tags.map { .string($0) }), "last_triggered": lastTriggered.map { .string($0.ISO8601Format()) } ?? .null]
    }
}
