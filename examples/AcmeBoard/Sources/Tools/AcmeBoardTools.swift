import DashKit

/// Acme Board's tools and Dashii function.
@MainActor
enum AcmeBoardTools {
    struct Summary: Codable, Sendable, Equatable {
        var summary: String
    }

    /// One narrow job for a smaller model, typed: the answer is decoded and checked for you.
    static let summary = DashiiFunction<[JSONValue], Summary>(
        name: "acme-board.summary", summary: "Summarize Acme tickets in two sentences.", task: "summary",
        instructions: "Summarize the tickets in two plain sentences: urgent work first, then what is in progress.",
        inputSchema: JSONSchema.array("Tickets.", of: JSONSchema.object(properties: ["title": JSONSchema.string(""), "status": JSONSchema.string("")],
                                                                        required: ["title", "status"])),
        outputSchema: JSONSchema.object(properties: ["summary": JSONSchema.string("")], required: ["summary"]),
        model: .fast, effort: .low, inputFormat: .compact, cacheFor: .seconds(600))

    static func tools(feature: AcmeBoardFeature) -> [DashiiTool] {
        [
            DashiiTool(name: "acme_board_tickets", description: "The Acme tickets Dash has: id, title, status, priority, assignee.") { [weak feature] _ in
                .array((feature?.tickets ?? []).map(\.json))
            },
            DashiiTool(name: "acme_board_summarize", description: "Summarize the open Acme tickets (a smaller model reads them).") { [weak feature] _ in
                guard let feature else { return nil }
                let host = try feature.requireHost()
                let open = feature.tickets.filter { $0.status != "done" }.map(\.json)
                let result = try await summary.run(open, dashii: host.dashii, settings: host.aiSettings(.extension(feature.id), tasks: feature.aiTasks))
                return .string(result.summary)
            },
        ]
    }
}
