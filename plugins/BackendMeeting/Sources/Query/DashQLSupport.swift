import DashKit
import Foundation
import SwiftUI

/// Applies a widget's DashQL query (its query bar) to the items it lists: the query filters,
/// sorts and cuts, and the widget shows the items it kept, in the query's order.
@MainActor
enum QueryRows {
    /// The ids the query keeps, in order; nil when there's no query (show everything).
    static func ids<Item: Identifiable>(_ query: WidgetQuery?, _ items: [Item], row: (Item) -> JSONValue) async -> [Item.ID]? {
        guard let query else { return nil }
        return await query.apply(to: items, row: row).map(\.id)
    }

    /// `items` narrowed to `ids` (in their order); all of them when `ids` is nil.
    static func ordered<Item: Identifiable>(_ items: [Item], by ids: [Item.ID]?) -> [Item] {
        guard let ids else { return items }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// What to recompute on: the query and the rows' content.
    static func key<Item>(_ text: String, _ items: [Item], row: (Item) -> JSONValue) -> String {
        "\(text)|\(items.map { row($0).jsonString() }.joined(separator: "\n").hashValue)"
    }
}

extension Date {
    var queryValue: JSONValue { .string(formatted(.iso8601)) }
}

extension Optional where Wrapped == Date {
    var queryValue: JSONValue { map { .string($0.formatted(.iso8601)) } ?? .null }
}

extension Optional where Wrapped == String {
    var queryValue: JSONValue { map(JSONValue.string) ?? .null }
}

/// A count of what a query kept, for widget headers: "12 of 40".
struct QueryCount: View {
    let shown: Int
    let total: Int
    let query: String

    var body: some View {
        if !query.isEmpty {
            Label("\(shown) of \(total)", systemImage: "line.3.horizontal.decrease")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Filtered by DashQL: \(query)")
        }
    }
}
