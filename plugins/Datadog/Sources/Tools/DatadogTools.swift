import DashKit
import Foundation

/// Dashii and agents get the readers: they answer from what the fetchers stored in Dash. Nothing
/// here calls Datadog; `data_fetch datadog.<what>` does, and Datadog only ever gets reads (GETs,
/// plus the logs search, a POST that reads).
extension DatadogIntegration {
    var tools: [DashiiTool] { readers }

    /// A log line, without the bulk of its attributes.
    nonisolated static func log(_ item: JSONValue) -> JSONValue {
        let attributes = item["attributes"]
        var message = attributes?["message"]?.string ?? ""
        if message.count > 1_000 { message = String(message.prefix(1_000)) + "…" }
        return ["timestamp": attributes?["timestamp"] ?? .null, "service": attributes?["service"] ?? .null,
                "status": attributes?["status"] ?? .null, "host": attributes?["host"] ?? .null, "message": .string(message)]
    }
}
