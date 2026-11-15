import DashKit
import Foundation

/// Datadog monitors for DashQL: the `monitors` dataset (the ones Dash checks every minute) and the
/// Monitors widget's query bar.
extension DatadogMonitor {
    static let queryFields: [QueryDataset.Field] = [
        .init("id", "number", "Monitor id"),
        .init("name", "string", "Monitor name"),
        .init("status", "string", "Alert, Warn, No Data, OK…", aliases: ["state"]),
        .init("type", "string", "metric alert, query alert, service check…"),
        .init("tags", "list", "Tags, e.g. service:api, env:prod"),
        .init("service", "string", "The service:… tag"),
        .init("env", "string", "The env:… tag"),
        .init("severity", "number", "0 Alert, 1 Warn, 2 No Data, 3 other"),
        .init("last_triggered", "date", "When it last triggered", aliases: ["triggered"]),
        .init("url", "string", "Link in Datadog"),
    ]

    func queryRow(url: URL?) -> JSONValue {
        func tag(_ name: String) -> JSONValue {
            tags.first { $0.hasPrefix(name + ":") }.map { .string(String($0.dropFirst(name.count + 1))) } ?? .null
        }
        return [
            "id": .number(Double(id)), "name": .string(name), "status": .string(status), "type": .string(type),
            "tags": .array(tags.map(JSONValue.string)), "service": tag("service"), "env": tag("env"),
            "severity": .number(Double(severity)), "last_triggered": lastTriggered.queryValue,
            "url": url.map { .string($0.absoluteString) } ?? .null,
        ]
    }
}

extension DatadogMonitorsFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "monitors", summary: "Datadog monitors not OK (Alert, Warn, No Data), checked every minute.",
                      fields: DatadogMonitor.queryFields) { [weak self] _ in
            guard let self else { return [] }
            return monitors.map { $0.queryRow(url: monitorURL($0)) }
        }]
    }
}
