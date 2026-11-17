import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls Datadog and stores a sanitized answer with a receipt; each
/// reader answers from the store with its freshness, or says what to fetch. No tool Dashii or an
/// agent gets makes a request. Every test has its own stub site.
@MainActor
struct DatadogFetchTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fetcher: String
        let input: JSONValue
        let routes: [String: String]
        /// A request the fetch must make.
        let path: String
        let check: @Sendable (JSONValue) -> Bool
        var testDescription: String { fetcher }
    }

    nonisolated static let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    nonisolated static let monitors = #"""
        {"monitors": [{"id": 2, "name": "Disk", "status": "Warn", "type": "metric alert", "tags": ["env:prod"]},
                      {"id": 1, "name": "Latency", "status": "Alert", "type": "query alert", "tags": ["service:billing-api"]}]}
        """#
    nonisolated static let logs = #"""
        {"data": [{"attributes": {"timestamp": "2026-11-17T10:02:00Z", "service": "billing-api", "status": "error", "host": "h1",
                                  "message": "retry failed with GITHUB_TOKEN=\#(token)", "attributes": {"big": 1}}}]}
        """#
    nonisolated static let events = #"""
        {"data": [{"id": "e1", "attributes": {"timestamp": "2026-11-17T10:01:00Z", "message": "Rolled out", "tags": ["service:billing-api"],
                                              "attributes": {"title": "Deployed billing-api v1.42", "service": "billing-api"}}}]}
        """#

    nonisolated static let cases: [Case] = [
        Case(fetcher: "datadog.monitors", input: [:], routes: ["/api/v1/monitor/search": monitors],
             path: "/api/v1/monitor/search") { $0["items"]?.array?.compactMap { $0["name"]?.string } == ["Disk", "Latency"] },
        Case(fetcher: "datadog.monitor", input: ["id": "1"], routes: ["/api/v1/monitor/1": #"{"id": 1, "name": "Latency", "query": "avg(last_5m):p95 > 2"}"#],
             path: "/api/v1/monitor/1") { $0["name"] == "Latency" && $0["query"] != nil },
        Case(fetcher: "datadog.metrics", input: ["query": "avg:system.cpu.user{service:billing-api}"],
             routes: ["/api/v1/query": #"{"series": [{"metric": "system.cpu.user", "pointlist": [[1, 2]]}]}"#],
             path: "/api/v1/query") { $0["series"]?[0]?["metric"] == "system.cpu.user" },
        Case(fetcher: "datadog.logs", input: ["query": "service:billing-api status:error"], routes: ["/api/v2/logs/events/search": logs],
             path: "/api/v2/logs/events/search") { $0["items"]?[0]?["service"] == "billing-api" && $0["items"]?[0]?["attributes"] == nil
                 && $0["items"]?[0]?["message"]?.string?.contains("ghp_") == false },
        Case(fetcher: "datadog.events", input: ["query": "service:billing-api"], routes: ["/api/v2/events": events],
             path: "/api/v2/events") { $0["data"]?[0]?["id"] == "e1" },
        Case(fetcher: "datadog.incidents", input: [:], routes: ["/api/v2/incidents/search": #"{"data": {"attributes": {"incidents": [{"data": {"id": "i1"}}]}}}"#],
             path: "/api/v2/incidents/search") { $0["data"]?["attributes"]?["incidents"]?[0]?["data"]?["id"] == "i1" },
        Case(fetcher: "datadog.dashboards", input: ["query": "billing"],
             routes: ["/api/v1/dashboard": #"{"dashboards": [{"id": "abc-def", "title": "Billing API", "url": "/dashboard/abc-def"}, {"id": "x", "title": "Other"}]}"#],
             path: "/api/v1/dashboard") { $0["items"]?.array?.count == 1 && $0["items"]?[0]?["url"]?.string?.hasSuffix("/dashboard/abc-def") == true },
        Case(fetcher: "datadog.dashboard", input: ["id": "abc-def"], routes: ["/api/v1/dashboard/abc-def": #"{"title": "Billing API", "widgets": []}"#],
             path: "/api/v1/dashboard/abc-def") { $0["title"] == "Billing API" },
        Case(fetcher: "datadog.slos", input: ["query": "service:billing-api"], routes: ["/api/v1/slo": #"{"data": [{"id": "s1", "name": "Availability"}]}"#],
             path: "/api/v1/slo") { $0["data"]?[0]?["id"] == "s1" },
        Case(fetcher: "datadog.slo_history", input: ["id": "s1"], routes: ["/api/v1/slo/s1/history": #"{"data": {"overall": {"sli_value": 99.9}}}"#],
             path: "/api/v1/slo/s1/history") { $0["data"]?["overall"]?["sli_value"] == 99.9 },
        Case(fetcher: "datadog.hosts", input: ["filter": "env:prod"], routes: ["/api/v1/hosts": #"{"host_list": [{"host_name": "h1", "up": true}]}"#],
             path: "/api/v1/hosts") { $0["items"]?[0]?["name"] == "h1" && $0["items"]?[0]?["up"] == true },
        Case(fetcher: "datadog.services", input: [:],
             routes: ["/api/v2/services/definitions": #"{"data": [{"attributes": {"schema": {"dd-service": "billing-api", "team": "payments"}}}]}"#],
             path: "/api/v2/services/definitions") { $0["items"]?[0]?["service"] == "billing-api" && $0["items"]?[0]?["team"] == "payments" },
        Case(fetcher: "datadog.api", input: ["path": "/api/v1/downtime?current_only=true"], routes: ["/api/v1/downtime": #"{"data": [{"id": "d1"}]}"#],
             path: "/api/v1/downtime") { $0["data"]?[0]?["id"] == "d1" },
    ]

    let site = "dd-\(UUID().uuidString.prefix(8).lowercased()).test"
    var stub: String { "api." + site }
    let dash: TestHost
    let datadog: DatadogIntegration

    init() throws {
        let defaults = UserDefaults(suiteName: "dd-fetch-\(UUID())")!
        defaults.set(site, forKey: "datadog.site")
        datadog = DatadogIntegration(defaults: defaults, secret: { "key-\($0)" }, session: StubHTTP.session)
        dash = try TestHost([datadog])
        dash.start([datadog])
    }

    func serve(_ routes: [String: String]) {
        StubHTTP.serve(stub, routes: routes.merging(["/api/v1/validate": #"{"valid": true}"#]) { mine, _ in mine })
    }

    func resource(_ fetcher: String) throws -> DatadogResource {
        try #require(datadog.resources.first { $0.fetcherName == fetcher })
    }

    // MARK: Fetchers and readers

    @Test(arguments: cases)
    func fetcherStoresAndReaderReads(_ c: Case) async throws {
        serve(c.routes)
        let resource = try resource(c.fetcher)

        let before = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(before["fetched"] == false && before["rows"] == [])
        #expect(before["refresh"]?["fetcher"] == .string(c.fetcher))

        let receipt = try await dash.fetch(c.fetcher, c.input)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0)
        #expect(receipt["keys"]?.array?.count == 1 && receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
        #expect(receipt["synced_at"]?.string != nil)
        #expect(receipt["read_with"]?.string?.hasPrefix(resource.readerName + " {") == true)
        let sent = StubHTTP.requests(stub)
        #expect(sent.contains { $0.url?.path() == c.path })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "DD-API-KEY") == "key-api_key" && $0.value(forHTTPHeaderField: "DD-APPLICATION-KEY") == "key-app_key" })
        #expect(sent.allSatisfy { $0.httpMethod == "GET" || $0.url?.path() == "/api/v2/logs/events/search" })

        let answer = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(c.check(answer), "\(answer.jsonString())")
        #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)
        #expect(answer["refresh"]?["fetcher"] == .string(c.fetcher))

        let again = try await dash.fetch(c.fetcher, c.input)
        #expect(again["stored"] == 0 && again["unchanged"] == 1)
        let stored = dash.testSynced.records(kind: resource.kind, scope: datadog.storeScope)
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { !$0.value.jsonString().contains("ghp_") && !$0.value.jsonString().contains("key-api_key") && $0.source == "datadog" })
    }

    @Test func readersSayWhenDataIsStale() async throws {
        serve(["/api/v1/monitor/search": Self.monitors, "/api/v1/dashboard": #"{"dashboards": []}"#])
        _ = try await dash.fetch("datadog.monitors", [:])
        _ = try await dash.fetch("datadog.dashboards", [:])
        datadog.now = { .now.addingTimeInterval(2 * 60) }
        let monitors = try #require(try await dash.runTool("datadog_monitors", [:]))
        #expect(monitors["stale"] == true && monitors["items"]?.array?.count == 2)
        #expect(monitors["refresh"] == ["fetcher": "datadog.monitors", "input": [:]])
        // Dashboards stay fresh for an hour.
        #expect(try await dash.runTool("datadog_dashboards", [:])?["stale"] == false)
    }

    @Test func inputsAreNormalized() async throws {
        serve(["/api/v1/monitor/search": Self.monitors])
        _ = try await dash.fetch("datadog.monitors", ["query": "status:alert"])
        let answer = try #require(try await dash.runTool("datadog_monitors", ["query": "  status:alert ", "extra": 1]))
        #expect(answer.object?.keys.contains("fetched") == false && answer["items"]?.array?.count == 2)
        await #expect(throws: ToolError("Give id.")) { _ = try await dash.runTool("datadog_monitor", [:]) }
        await #expect(throws: ToolError("Give query.")) { _ = try await dash.runTool("datadog_logs_search", ["query": " "]) }
    }

    @Test func queryAnswersExpireAfterADay() async throws {
        serve(["/api/v1/monitor/search": Self.monitors])
        _ = try await dash.fetch("datadog.monitors", [:])
        datadog.now = { .now.addingTimeInterval(2 * 86_400) }
        _ = try await dash.fetch("datadog.monitors", ["query": "status:alert"])
        let stored = dash.testSynced.records(kind: "datadog.monitors", scope: datadog.storeScope)
        #expect(stored.map { $0.value["input"]?["query"] } == ["status:alert"])
    }

    @Test func rawPathsAreCheckedAndBigAnswersCapped() async throws {
        serve(["/api/v1/downtime": "{\"blob\":\"\(String(repeating: "a", count: 300_000))\"}"])
        _ = try await dash.fetch("datadog.api", ["path": "/api/v1/downtime"])
        let stored = try #require(dash.testSynced.records(kind: "datadog.api", scope: datadog.storeScope).first)
        #expect(stored.value["data"]?["truncated"] == true)
        #expect(stored.value.jsonString().utf8.count < 201_000)
        let before = StubHTTP.requests(stub).count
        for bad in ["https://evil.example/api/v1/x", "/v1/monitor", "/api/../oauth"] {
            await #expect(throws: ToolError.self) { _ = try await dash.fetch("datadog.api", ["path": .string(bad)]) }
            await #expect(throws: ToolError.self) { _ = try await dash.runTool("datadog_api_read", ["path": .string(bad)]) }
        }
        #expect(StubHTTP.requests(stub).count == before)
    }

    @Test func recordsArePerSite() async throws {
        serve(["/api/v1/monitor/search": Self.monitors])
        _ = try await dash.fetch("datadog.monitors", [:])
        #expect(datadog.storeScope == "datadog:" + site)
        #expect(dash.testSynced.records(kind: "datadog.monitors", scope: "datadog:datadoghq.eu").isEmpty)
    }

    // MARK: No network for Dashii and agents

    @Test func noToolDashiiGetsCallsDatadog() async throws {
        let values: [String: JSONValue] = ["id": "1", "query": "service:billing-api", "path": "/api/v1/downtime", "filter": "env:prod"]
        #expect(await NetworkSentinel.requests(running: datadog.tools, values: values) == [])
        // With data stored, the readers still only read.
        serve(["/api/v1/monitor/search": Self.monitors, "/api/v2/logs/events/search": Self.logs])
        _ = try await dash.fetch("datadog.monitors", ["query": "service:billing-api"])
        _ = try await dash.fetch("datadog.logs", ["query": "service:billing-api"])
        #expect(await NetworkSentinel.requests(running: datadog.tools, values: values) == [])
    }

    @Test func toolsFetchersAndVerbsLineUp() throws {
        let tools = datadog.tools
        #expect(tools.map(\.name) == datadog.resources.map(\.readerName))
        #expect(tools.allSatisfy { $0.isForDashii && !$0.callsService && !$0.requiresApproval && !$0.writesRemotely })
        #expect(!tools.contains { $0.name == "datadog_api_get" })
        let fetchers = datadog.fetchers.map(\.name)
        #expect(fetchers.count == datadog.resources.count && fetchers.allSatisfy { $0.hasPrefix("datadog.") } && Set(fetchers).count == fetchers.count)
        #expect(datadog.verbs.allSatisfy { verb in tools.contains { $0.name == verb.tool } })
        #expect(datadog.datasets.map(\.name) == ["datadog_logs", "datadog_events"])
    }

    @Test func datasetsReadStoredAnswers() async throws {
        serve(["/api/v2/logs/events/search": Self.logs, "/api/v2/events": Self.events])
        let logs = try #require(datadog.datasets.first { $0.name == "datadog_logs" })
        #expect(try await logs.rows(nil).isEmpty)
        _ = try await dash.fetch("datadog.logs", ["query": "service:billing-api"])
        _ = try await dash.fetch("datadog.events", ["query": "service:billing-api"])
        let rows = try await logs.rows(nil)
        #expect(rows.count == 1 && rows.first?["service"] == "billing-api" && rows.first?["query"] == "service:billing-api")
        #expect(rows.first?["stale"] == false && rows.first?["synced_at"]?.string != nil)
        let events = try await #require(datadog.datasets.first { $0.name == "datadog_events" }).rows(nil)
        #expect(events.first?["title"] == "Deployed billing-api v1.42" && events.first?["service"] == "billing-api" && events.first?["id"] == "e1")
    }
}
