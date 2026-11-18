import DashKit
import Foundation

/// Something Dash can fetch from AWS and read back: the fetcher `aws.<what>` calls the API (in
/// the integration's region) and stores the answer; the reader (same input) returns it with its
/// freshness, or says to fetch first.
struct AWSResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    var required: [String] = []
    /// Answers to a query (logs, raw calls): kept a day, then dropped.
    var queryShaped = false
    var freshFor: Duration = .seconds(5 * 60)
    /// The reader's name when it isn't `aws_<what>`.
    var reader: String?
    /// Calls AWS and returns the answer that gets stored.
    let load: @MainActor (AWSIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "aws." + what }
    var readerName: String { reader ?? "aws_" + what }
    var kind: String { "aws." + what }
}

extension AWSIntegration {
    /// What Dash fetches from AWS: the JSON APIs asked for most, and any read-only call.
    var resources: [AWSResource] {
        [
            AWSResource(what: "log_groups", summary: "CloudWatch Logs log groups: name, stored bytes, retention and creation time.",
                        properties: ["prefix": JSONSchema.string("Only groups whose name starts with this, e.g. /aws/lambda/billing.")],
                        freshFor: .seconds(15 * 60)) { aws, input in
                try await aws.logGroups(prefix: input["prefix"]?.string)
            },
            AWSResource(what: "logs", summary: "CloudWatch Logs events of a log group, newest first (FilterLogEvents): timestamp, stream and message.",
                        properties: [
                            "group": JSONSchema.string("Log group name, e.g. /aws/lambda/billing-api."),
                            "filter": JSONSchema.string("CloudWatch filter pattern, e.g. ERROR or { $.level = \"error\" }."),
                            "minutes": JSONSchema.integer("How far back, in minutes (default 60, at most 10080)."),
                            "limit": JSONSchema.integer("Max events, 1-1000 (default 200)."),
                        ],
                        required: ["group"], queryShaped: true) { aws, input in
                try await aws.logEvents(input)
            },
            AWSResource(what: "lambda_functions", summary: "Lambda functions: name, runtime, handler, memory, timeout, code size and last change.",
                        properties: [:], freshFor: .seconds(15 * 60)) { aws, _ in
                try await aws.lambdaFunctions()
            },
            AWSResource(what: "eks_clusters", summary: "EKS clusters: name, Kubernetes version, status, platform version, endpoint and creation time.",
                        properties: [:], freshFor: .seconds(3600)) { aws, _ in
                try await aws.eksClusters()
            },
            AWSResource(what: "api", summary: """
                Any read-only AWS API call, signed with SigV4, when no other AWS fetcher fits. Give the full https URL on *.amazonaws.com \
                (the service and region come from the host). Query APIs: POST form body "Action=DescribeInstances&Version=2016-11-15". \
                JSON APIs: content_type application/x-amz-json-1.1 plus target, e.g. "Logs_20140328.DescribeLogGroups". \
                Only Describe/List/Get-style actions (and GET requests) run; anything that changes AWS is refused.
                """,
                        properties: [
                            "method": JSONSchema.string("HTTP method (default POST).", enum: ["GET", "POST"]),
                            "url": JSONSchema.string("Full URL, e.g. https://ec2.eu-west-1.amazonaws.com/"),
                            "body": JSONSchema.string("Request body (form or JSON text)."),
                            "content_type": JSONSchema.string("Content-Type (default application/x-www-form-urlencoded; charset=utf-8)."),
                            "target": JSONSchema.string("X-Amz-Target for JSON-protocol services."),
                        ],
                        required: ["url"], queryShaped: true, reader: "aws_api_read") { aws, input in
                try await aws.apiCall(input)
            },
        ]
    }

    /// The `aws.api` request, checked: https on `*.amazonaws.com` and a read-only action.
    nonisolated static func apiRequest(_ input: JSONValue) throws -> URLRequest {
        let text = input["url"]?.string ?? ""
        guard let url = URL(string: text), url.scheme == "https", let host = url.host(), host.hasSuffix(".amazonaws.com") else {
            throw ToolError("Only https://*.amazonaws.com URLs can be signed.")
        }
        let method = (input["method"]?.string ?? "POST").uppercased()
        let body = input["body"]?.string
        let target = input["target"]?.string
        try requireReadOnly(method: method, url: url, body: body, target: target)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue(input["content_type"]?.string ?? "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let target { request.setValue(target, forHTTPHeaderField: "X-Amz-Target") }
        return request
    }

    func apiCall(_ input: JSONValue) async throws -> JSONValue {
        let (data, _) = try await send(try Self.apiRequest(input))
        let text = String(decoding: data, as: UTF8.self)
        return text.count > Self.maxToolCharacters
            ? .string(String(text.prefix(Self.maxToolCharacters)) + "\n[truncated]") : ((try? JSONValue.parse(data)) ?? .string(text))
    }

    /// A JSON-protocol call (`X-Amz-Target`) to a service in the integration's region.
    func jsonCall(_ service: String, target: String, _ body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://\(service).\(region).amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = Data(body.jsonString().utf8)
        let (data, _) = try await send(request)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    /// A GET on a REST-JSON service in the integration's region.
    func restGet(_ service: String, _ path: String, _ query: [String: String?] = [:]) async throws -> JSONValue {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(service).\(region).amazonaws.com"
        components.path = path
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { throw ToolError("Bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, _) = try await send(request)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    func logGroups(prefix: String?) async throws -> JSONValue {
        var groups: [JSONValue] = []
        var token: String?
        for _ in 0..<5 {
            var body: [String: JSONValue] = ["limit": 50]
            if let prefix { body["logGroupNamePrefix"] = .string(prefix) }
            if let token { body["nextToken"] = .string(token) }
            let page = try await jsonCall("logs", target: "Logs_20140328.DescribeLogGroups", .object(body))
            groups += page["logGroups"]?.array ?? []
            token = page["nextToken"]?.string
            if token?.isEmpty ?? true { break }
        }
        return .array(groups.map { group in
            ["name": group["logGroupName"] ?? .null, "stored_bytes": group["storedBytes"] ?? .null,
             "retention_days": group["retentionInDays"] ?? .null, "created": Self.time(group["creationTime"]), "class": group["logGroupClass"] ?? .null]
        })
    }

    /// The window's matching events (up to 10 pages), the latest `limit` of them, newest first.
    func logEvents(_ input: JSONValue) async throws -> JSONValue {
        let group = input["group"]?.string ?? ""
        let minutes = min(max(input["minutes"]?.int ?? 60, 1), 10_080)
        let limit = min(max(input["limit"]?.int ?? 200, 1), 1000)
        let start = now().addingTimeInterval(-Double(minutes) * 60)
        var events: [JSONValue] = []
        var token: String?
        for _ in 0..<10 {
            var body: [String: JSONValue] = ["logGroupName": .string(group), "startTime": .number((start.timeIntervalSince1970 * 1000).rounded()), "limit": .number(Double(limit))]
            if let filter = input["filter"]?.string { body["filterPattern"] = .string(filter) }
            if let token { body["nextToken"] = .string(token) }
            let page = try await jsonCall("logs", target: "Logs_20140328.FilterLogEvents", .object(body))
            events += page["events"]?.array ?? []
            token = page["nextToken"]?.string
            if token?.isEmpty ?? true { break }
        }
        let latest = events.sorted { ($0["timestamp"]?.double ?? 0) > ($1["timestamp"]?.double ?? 0) }.prefix(limit)
        return ["group": .string(group), "since": .string(start.formatted(.iso8601)), "events": .array(latest.map { event in
            ["timestamp": Self.time(event["timestamp"]), "stream": event["logStreamName"] ?? .null,
             "message": .string(String((event["message"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)))]
        })]
    }

    func lambdaFunctions() async throws -> JSONValue {
        var functions: [JSONValue] = []
        var marker: String?
        for _ in 0..<5 {
            let page = try await restGet("lambda", "/2015-03-31/functions/", ["MaxItems": "50", "Marker": marker])
            functions += page["Functions"]?.array ?? []
            marker = page["NextMarker"]?.string
            if marker?.isEmpty ?? true { break }
        }
        return .array(functions.map { function in
            ["name": function["FunctionName"] ?? .null, "runtime": function["Runtime"] ?? function["PackageType"] ?? .null,
             "handler": function["Handler"] ?? .null, "memory": function["MemorySize"] ?? .null, "timeout": function["Timeout"] ?? .null,
             "code_size": function["CodeSize"] ?? .null, "last_modified": function["LastModified"] ?? .null]
        })
    }

    /// Up to 20 clusters, each described.
    func eksClusters() async throws -> JSONValue {
        let names = (try await restGet("eks", "/clusters", ["maxResults": "100"])["clusters"]?.array ?? []).compactMap(\.string)
        var clusters: [JSONValue] = []
        for name in names.prefix(20) where Self.isPlainName(name) {
            let cluster = try await restGet("eks", "/clusters/" + name)["cluster"] ?? .null
            clusters.append(["name": .string(name), "version": cluster["version"] ?? .null, "status": cluster["status"] ?? .null,
                             "platform": cluster["platformVersion"] ?? .null, "endpoint": cluster["endpoint"] ?? .null,
                             "created": Self.time(cluster["createdAt"])])
        }
        return .array(clusters)
    }

    /// Letters, digits, `-` and `_`: safe as a URL path segment.
    nonisolated static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    /// AWS times come as epoch milliseconds (Logs) or seconds (EKS); ISO-8601 out.
    nonisolated static func time(_ value: JSONValue?) -> JSONValue {
        guard let number = value?.double else { return value ?? .null }
        let seconds = number > 100_000_000_000 ? number / 1000 : number
        return .string(Date(timeIntervalSince1970: seconds).formatted(.iso8601))
    }
}
