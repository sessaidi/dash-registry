import DashKit
import Foundation
import Ingestor

/// Fetch, then read, through Ingestor: fetchers store GitHub's answers in Dash's mirror
/// (`host.synced`), sanitized and capped at 200 KB; the Dashii tools read them back with their
/// freshness. Records are per API host (github.com or an Enterprise server), kind
/// `github.<what>`, keyed by the normalized input's hash; the value keeps the input next to the data.
extension GitHubIntegration {
    var storeScope: String { "github:" + (URL(string: apiURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host() ?? "api.github.com") }
    var maxAge: Duration { .seconds(freshMinutes * 60) }

    /// Stores and reads the resources; repositories in lower case (GitHub ignores case there).
    var ingestor: Ingestor {
        var ingestor = Ingestor(source: id, scope: storeScope, store: host?.synced, maxAge: maxAge, notStarted: "GitHub isn't started.")
        ingestor.clock = { [weak self] in self?.now() ?? .now }
        ingestor.transform = { field, value in field == "repo" ? value.lowercased() : value }
        ingestor.validate = { input in if input["repo"] != nil { _ = try Self.repoPath(input) } }
        ingestor.database = database
        ingestor.tables = ingestTables
        return ingestor
    }

    /// GETs for the resources: the last answer's ETag goes along (a 304 costs no rate limit) and
    /// a used-up rate limit stops the calls until it resets.
    var ingestClient: IngestClient {
        get throws {
            var client = IngestClient(connection: try toolAPI.connection, service: GitHubAPI.service, scope: storeScope, store: host?.synced, source: id)
            client.clock = { [weak self] in self?.now() ?? .now }
            return client
        }
    }

    var ingestResources: [IngestResource] {
        resources.map { resource in
            IngestResource(kind: resource.kind, fetcher: resource.fetcherName, reader: resource.readerName, summary: resource.summary,
                           properties: resource.properties, required: resource.required, queryShaped: resource.queryShaped) { [weak self] input in
                guard let self else { throw ToolError("GitHub isn't started.") }
                return try await resource.load(self, input)
            }
        }
    }

    var fetchers: [DataFetcher] {
        Ingestor.fetchers(ingestResources) { [weak self] in self?.ingestor } + releaseFetchers
    }

    /// The readers Dashii and agents use: same names and inputs as the old live tools.
    var readers: [DashiiTool] {
        Ingestor.readers(ingestResources) { [weak self] in self?.ingestor }
    }
}
