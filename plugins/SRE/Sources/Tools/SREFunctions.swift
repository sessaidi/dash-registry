import DashKit

/// Functions the SRE offers to others (Dashii, agents, other plugins), on top of DashKit's.
enum SREFunctions {
    struct SeverityInput: Codable, Sendable {
        var symptom: String
        /// What is known: alerting monitors, failing pods, error rates, affected users.
        var signals: [String]
    }

    struct Severity: Codable, Sendable, Equatable {
        /// S1 down or data loss, S2 major feature broken, S3 degraded with a workaround, S4 cosmetic.
        var severity: String
        var page: Bool
        var blastRadius: String
        var reason: String
    }

    static let severity = DashiiFunction<SeverityInput, Severity>(
        name: "sre.severity", summary: "Rate an incident S1–S4, whether to page someone now, and its blast radius, from a symptom and signals.",
        task: "severity",
        instructions: """
            Rate the incident from the signals only. S1: down or data loss; S2: a major feature broken without workaround; \
            S3: degraded with a workaround; S4: cosmetic. page is true for S1 and S2, and for S3 that is getting worse. \
            blastRadius names who or what is affected. reason is one sentence citing the signals.
            """,
        inputSchema: JSONSchema.object(properties: ["symptom": JSONSchema.string("What's wrong."),
                                                    "signals": JSONSchema.array("What is known.", of: JSONSchema.string(""))], required: ["symptom", "signals"]),
        outputSchema: JSONSchema.object(properties: [
            "severity": JSONSchema.string("", enum: ["S1", "S2", "S3", "S4"]), "page": JSONSchema.boolean(""),
            "blastRadius": JSONSchema.string(""), "reason": JSONSchema.string(""),
        ], required: ["severity", "page", "blastRadius", "reason"]),
        model: .fast, effort: .low,
        check: { guard ["S1", "S2", "S3", "S4"].contains($0.severity) else { throw ToolError("severity must be S1, S2, S3 or S4") } })
}
