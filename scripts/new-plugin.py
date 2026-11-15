#!/usr/bin/env python3
"""Creates a new Dash plugin under plugins/<Name>: a buildable, tested starting point on DashKit 2,
laid out like docs/PLUGINS.md describes (Tools/, Query/, Widgets/<Name>/, Rules/).

    scripts/new-plugin.py Weather --feature
    scripts/new-plugin.py Linear --integration --author "Ada <ada@example.com>"
    scripts/new-plugin.py Standup --feature --requires atlassian,github

An integration holds an account (token in the Keychain, an authenticated connection, a status)
and a read tool. A feature adds a widget (provider, snapshot, view, sample preview), a tool, a
Dashii function, a DashQL dataset and statements, hook presets and rules, and uses integrations
only through DashKit. Build and test it with:

    TEST=1 scripts/build-plugins.sh <Name>
"""
import argparse
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("name", help="PascalCase name, e.g. Weather")
kind = parser.add_mutually_exclusive_group(required=True)
kind.add_argument("--integration", action="store_true")
kind.add_argument("--feature", action="store_true")
parser.add_argument("--id", help="extension id (default: kebab-case of the name)")
parser.add_argument("--requires", default="", help="comma-separated integration ids a feature needs")
parser.add_argument("--author", default="Dash", help='"Name" or "Name <email>"')
parser.add_argument("--bundle-prefix", default="dev.sessaidi.Dash.plugin", help="bundle identifier prefix")
args = parser.parse_args()

name = args.name
if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", name):
    sys.exit("name must be PascalCase letters and digits, e.g. Weather")
plugin_id = args.id or re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()
requires = [r.strip() for r in args.requires.split(",") if r.strip()]
author_match = re.fullmatch(r"\s*(.*?)\s*(?:<(.+)>)?\s*", args.author)
author_name, author_email = author_match.group(1), author_match.group(2)
folder = root / "plugins" / name
if folder.exists():
    sys.exit(f"{folder} already exists")

tokens = {
    "__NAME__": name,
    "__ID__": plugin_id,
    "__IDU__": plugin_id.replace("-", "_"),
    "__AUTHOR__": f'ExtensionAuthor(name: "{author_name}"' + (f', email: "{author_email}")' if author_email else ")"),
    "__REQUIRES__": ", ".join(f'"{r}"' for r in requires),
    "__USES__": f" Uses {', '.join(requires)} through DashKit only." if requires else "",
    "__BUNDLE__": f"{args.bundle_prefix}.{plugin_id}",
    "__MAIN__": "Integration" if args.integration else "Feature",
}


def fill(text):
    for token, value in tokens.items():
        text = text.replace(token, value)
    return text


project = """# A Dash plugin. Build, test, zip and index it with: TEST=1 scripts/build-plugins.sh __NAME__
name: __NAME__Plugin
options:
  deploymentTarget: { macOS: "26.0" }
  createIntermediateGroups: true
packages:
  DashKit: { path: ../../../perso/dash/Packages/DashKit }
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
targets:
  __NAME__Plugin:
    type: bundle
    platform: macOS
    sources:
      - Sources
      - path: plugin.json       # the bundle describes itself (Contents/Resources/plugin.json)
        buildPhase: resources
      - path: Rules             # default rules for Dashii, as Markdown (Contents/Resources/Rules/<id>.md)
        type: folder
        buildPhase: resources
    dependencies:
      - package: DashKit
        product: DashKit
        embed: false            # Dash provides DashKit at runtime
    info:
      path: Info.plist
      properties:
        CFBundleExecutable: "$(EXECUTABLE_NAME)"
        DashPluginID: __ID__
        DashPluginVersion: "1.0.0"
        DashKitMinimumVersion: "2.0.0"
    settings:
      base:
        WRAPPER_EXTENSION: dashplugin
        PRODUCT_BUNDLE_IDENTIFIER: __BUNDLE__
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks @loader_path/../../../../Frameworks"
    scheme: {}
  __NAME__PluginTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Sources
      - Tests
      - path: Rules             # the rules load from the bundle the code runs in
        type: folder
        buildPhase: resources
    dependencies:
      - package: DashKit
        product: DashKit        # includes DashKitTesting
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: __BUNDLE__.tests
    scheme:
      testTargets: [__NAME__PluginTests]
"""

entry = """import DashKit

/// The extensions this plugin adds; Dash gets them through `dash_plugin_entry`.
enum __NAME__Plugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [__NAME____MAIN__()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { __NAME__Plugin.makeExtensions() }
}
"""

# MARK: Integration

integration = """import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The __NAME__ account: an API token in the Keychain and an authenticated connection that
/// features use without seeing the token.
@MainActor
@Observable
final class __NAME__Integration: Integration {
    let id = "__ID__"
    let name = "__NAME__"
    let systemImage = "link"
    let metadata = ExtensionMetadata(version: "1.0.0", author: __AUTHOR__,
                                     summary: "Connects your __NAME__ account.", category: .other, minimumDashKit: "2.0.0")
    let secretKeys = [SecretKey("token", "API token")]
    let secrets: SecretStore? = SecretStore(extensionID: "__ID__")

    /// The API every request goes to. Change it to the service's.
    static let apiURL = URL(string: "https://api.example.com")!

    @ObservationIgnored private let readToken: @MainActor () -> String?
    @ObservationIgnored private let session: URLSession?
    private(set) var account: String?
    private(set) var lastError: String?

    /// `token` and `session` are for tests; Dash uses the Keychain and the shared session.
    init(token: (@MainActor () -> String?)? = nil, session: URLSession? = nil) {
        let store = SecretStore(extensionID: "__ID__")
        readToken = token ?? { store.read("token") }
        self.session = session
    }

    private var token: String? { readToken().flatMap { $0.isEmpty ? nil : $0 } }
    var isConnected: Bool { token != nil }
    var connectionState: ConnectionState { state(error: lastError, configured: isConnected, account: account) }

    var connection: IntegrationConnection? {
        guard let token else { return nil }
        return IntegrationConnection(baseURL: Self.apiURL, headers: ["Authorization": "Bearer \\(token)"], session: session)
    }

    /// What features may read without the secret (e.g. the signed-in account).
    var exports: JSONValue { ["account": account.map { .string($0) } ?? .null] }

    var tools: [DashiiTool] { __NAME__Tools.tools(integration: self) }

    func start(host: any ExtensionContext) {
        Task { await verify() }
    }

    /// Checks the token once at launch, while the splash screen shows progress.
    func prepare(host: any ExtensionContext) async throws {
        await verify()
        if let lastError { throw ToolError(lastError) }
    }

    func setToken(_ token: String) {
        secrets?.write("token", token)
        account = nil
        Task { await verify() }
    }

    /// Asks the API who the token belongs to. Adjust the path and field to the service's.
    func verify() async {
        guard let connection else { lastError = nil; return }
        do {
            account = try await connection.get("/me", service: name)["name"]?.string
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func settingsView() -> AnyView { AnyView(__NAME__Settings(integration: self)) }
}

private struct __NAME__Settings: View {
    let integration: __NAME__Integration

    var body: some View {
        Form {
            Section {
                SecretField("API token", isStored: integration.isConnected, onSave: { integration.setToken($0) },
                            onRemove: { integration.setToken("") })
                LabeledContent("Status") { ConnectionStatusLabel(integration.connectionState) }
            } footer: {
                Text("Stored in your Keychain. Features use the connection; they never see the token.")
            }
        }
    }
}
"""

integration_tools = """import DashKit

/// __NAME__'s tools: reads only, so Dashii and read-only agents may use them.
@MainActor
enum __NAME__Tools {
    static func tools(integration: __NAME__Integration) -> [DashiiTool] {
        [DashiiTool(name: "__IDU___get", description: "GET a __NAME__ API path and return the JSON. Read-only.",
                    properties: ["path": JSONSchema.string("API path, e.g. /me.")], required: ["path"]) { [weak integration] input in
            guard let connection = integration?.connection else { throw ToolError("Connect __NAME__ in Settings.") }
            return try await connection.get(input["path"]?.string ?? "/", service: "__NAME__")
        }]
    }
}
"""

integration_rules = """- __NAME__ is read through `__IDU___get` (GET only); say which path you read.
- Never paste the API token or any credential.
"""

integration_tests = """import DashKit
import DashKitTesting
import Foundation
import Testing

@MainActor
struct __NAME__IntegrationTests {
    @Test func connectsWithATokenAndVerifiesTheAccount() async throws {
        let host = "api-\\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: ["/me": #"{"name": "ada"}"#])
        let integration = __NAME__Integration(token: { "secret" }, session: StubHTTP.session)
        #expect(integration.isConnected)
        // Point the connection at the stub (the real one uses apiURL).
        var connection = try #require(integration.connection)
        connection = IntegrationConnection(baseURL: URL(string: "https://\\(host)")!, headers: connection.headers, session: StubHTTP.session)
        #expect(try await connection.get("/me", service: "test")["name"] == "ada")
        #expect(StubHTTP.requests(host).first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func noTokenMeansNotConnected() {
        let integration = __NAME__Integration(token: { nil })
        #expect(!integration.isConnected && integration.connection == nil)
        #expect(integration.connectionState == .notConfigured)
        #expect(integration.tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
    }
}
"""

# MARK: Feature

feature = """import DashKit
import Foundation
import Observation
import SwiftUI

/// __NAME__: a widget, a tool, a Dashii function, a DashQL dataset and statements.__USES__
@MainActor
@Observable
final class __NAME__Feature: DashExtension {
    let id = "__ID__"
    let name = "__NAME__"
    let systemImage = "sparkles"
    let metadata = ExtensionMetadata(version: "1.0.0", author: __AUTHOR__,
                                     summary: "Describe what __NAME__ does.", category: .productivity, minimumDashKit: "2.0.0")
    let layer = ExtensionLayer.feature
    let requires: [String] = [__REQUIRES__]

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    private(set) var items: [__NAME__Item] = []

    var widgets: [WidgetType] { [WidgetType(MainWidget.self)] }
    var tools: [DashiiTool] { __NAME__Tools.tools(feature: self) }
    /// Offered to other extensions, Dashii and agents (`host.runFunction("__ID__.summary", …)`).
    var functions: [AnyDashiiFunction] { [__NAME__Tools.summary.erased] }
    /// The user picks the model and effort for the summary in the extension's AI tab.
    var aiTasks: [AITask] {
        [AITask(id: "summary", title: "Summaries", summary: "Summarizes the items.", models: [.fast, .balanced], defaultModel: .fast)]
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await refresh() }
    }

    /// Loads the items. Replace with real work (an integration's connection, a local API…).
    func refresh() async {
        items = [__NAME__Item(title: "First item", detail: "Replace with real data"), __NAME__Item(title: "Second item", detail: "Up to date")]
        host?.activity.emit("__ID__.refreshed", source: id, title: "__NAME__ refreshed", importance: .info)
    }

    func requireHost() throws -> any ExtensionContext {
        guard let host else { throw ToolError("__NAME__ isn't running.") }
        return host
    }
}

struct __NAME__Item: Identifiable, Hashable, Sendable, Codable {
    var id: String { title }
    let title: String
    let detail: String
}
"""

feature_tools = """import DashKit

/// __NAME__'s tools and Dashii functions.
@MainActor
enum __NAME__Tools {
    struct Summary: Codable, Sendable, Equatable {
        var summary: String
    }

    /// One narrow job for a smaller model, typed: the answer is decoded and checked for you.
    static let summary = DashiiFunction<[__NAME__Item], Summary>(
        name: "__ID__.summary", summary: "Summarize __NAME__ items in two sentences.", task: "summary",
        instructions: "Summarize the items in two plain sentences: what matters first.",
        inputSchema: JSONSchema.array("Items.", of: JSONSchema.object(properties: ["title": JSONSchema.string(""), "detail": JSONSchema.string("")],
                                                                      required: ["title", "detail"])),
        outputSchema: JSONSchema.object(properties: ["summary": JSONSchema.string("")], required: ["summary"]),
        model: .fast, effort: .low, inputFormat: .compact, cacheFor: .seconds(600))

    static func tools(feature: __NAME__Feature) -> [DashiiTool] {
        [
            DashiiTool(name: "__IDU___items", description: "List __NAME__'s items.") { [weak feature] _ in
                .array((feature?.items ?? []).map { ["title": .string($0.title), "detail": .string($0.detail)] })
            },
            DashiiTool(name: "__IDU___summarize", description: "Summarize __NAME__'s items (a smaller model reads them).") { [weak feature] _ in
                guard let feature else { return nil }
                let host = try feature.requireHost()
                let result = try await summary.run(feature.items, dashii: host.dashii, settings: host.aiSettings(.extension(feature.id), tasks: feature.aiTasks))
                return .string(result.summary)
            },
        ]
    }
}
"""

feature_query = """import DashKit

/// __NAME__ in DashQL (`from __IDU__`, `__ID__ summarize`) and ready-made hooks.
extension __NAME__Feature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "__IDU__", summary: "__NAME__'s items.",
                      fields: [.init("title", .string, "Title"), .init("detail", .string, "Detail")]) { [weak self] _ in
            (self?.items ?? []).map { ["title": .string($0.title), "detail": .string($0.detail)] }
        }]
    }

    var verbs: [DashQLVerb] {
        [DashQLVerb("__ID__", "items", tool: "__IDU___items", summary: "List the items."),
         DashQLVerb("__ID__", "summarize", tool: "__IDU___summarize", summary: "Summarize the items.")]
    }

    var hookPresets: [HookPresetSpec] {
        [.appears("__ID__.new-items", "New __NAME__ items", dataset: "__IDU__", where: "title != \\"\\"", key: "title",
                  title: "{{count}} new: {{first.title}}", body: "{{first.detail}}")]
    }
}
"""

widget = """import DashKit
import DashKitUI
import SwiftUI

/// The __NAME__ widget's manifest: what it is, its sizes and settings. Data comes from
/// `MainProvider`, drawing from `MainView`.
struct MainWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var limit: Int = 10
    }

    static let kind = "__ID__.main"
    static let displayName = "__NAME__"
    static let summary = "Describe what the widget shows."
    static let systemImage = "sparkles"
    static let defaultSize = WidgetSize.medium
    static let sizeLimits = GridLimits(minW: 3, minH: 3, maxW: 12, maxH: 20)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["limit": ["type": "integer", "description": "How many items to show."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ProvidedWidget(MainProvider(host: context.host), config: config.wrappedValue) { snapshot, size in
            MainView(snapshot: snapshot, size: size)
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Stepper("Show \\(config.wrappedValue.limit) items", value: config.limit, in: 1...50)
    }

    /// Sample data for the gallery: no network, no accounts.
    static func preview(config: Config) -> some View { MainView(snapshot: .sample, size: .regular) }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        (try? await MainProvider(host: context.host).snapshot(for: config)).map { snapshot in
            .array(snapshot.items.map { ["title": .string($0.title), "detail": .string($0.detail)] })
        } ?? .null
    }
}
"""

provider = """import DashKit

/// Where the widget's data comes from. Views never fetch; they render what this returns.
struct MainProvider: WidgetDataProvider {
    let host: any ExtensionContext

    var refresh: WidgetRefresh { .every(.seconds(120)) }

    func snapshot(for config: MainWidget.Config) async throws -> MainSnapshot {
        guard let feature = host.ext(__NAME__Feature.self) else { throw ToolError("__NAME__ isn't loaded.") }
        return MainSnapshot(items: Array(feature.items.prefix(config.limit)))
    }
}
"""

snapshot = """/// What the widget shows: plain data, so previews and tests need no services.
struct MainSnapshot: Sendable, Equatable {
    var items: [__NAME__Item]

    static let sample = MainSnapshot(items: [__NAME__Item(title: "Sample item", detail: "Shown in the gallery"),
                                             __NAME__Item(title: "Another", detail: "Sample data")])
}
"""

view = """import DashKit
import DashKitUI
import SwiftUI

/// Renders a snapshot; picks how much to show from the room it has.
struct MainView: View {
    let snapshot: MainSnapshot
    let size: WidgetSizeClass

    var body: some View {
        if snapshot.items.isEmpty {
            StateView(.empty(title: "Nothing yet", systemImage: "tray", message: nil))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.items.prefix(size == .compact ? 3 : 20)) { item in
                    ItemRow(item.title, subtitle: size == .compact ? nil : item.detail, leading: { StatusDot(.success) })
                }
                Spacer(minLength: 0)
            }
            .padding(size == .compact ? 8 : 12)
        }
    }
}
"""

feature_rules = """- __NAME__'s items: `__IDU___items`, or dashql `from __IDU__` (title, detail).
- Summaries go through `__IDU___summarize`; say they come from a smaller model.
"""

feature_tests = """import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

@MainActor
struct __NAME__FeatureTests {
    func make() throws -> (__NAME__Feature, TestHost) {
        let feature = __NAME__Feature()
        let host = try TestHost([feature])
        host.start([feature])
        return (feature, host)
    }

    @Test func refreshesAndListsItems() async throws {
        let (feature, host) = try make()
        await feature.refresh()
        let items = try await host.runTool("__IDU___items")
        #expect(items?.array?.count == 2)
        #expect(host.activity.events.contains { $0.kind == "__ID__.refreshed" })
    }

    @Test func summariesGoToASmallerModelWithTheAITabChoices() async throws {
        let (feature, host) = try make()
        await feature.refresh()
        host.aiChoices[.extension(feature.id)] = ["summary": AITaskChoice(model: .balanced)]
        host.testDashii.reply = #"{"summary":"All good."}"#
        #expect(try await host.runTool("__IDU___summarize") == "All good.")
        let call = try #require(host.testDashii.calls.last)
        #expect(call.model == DashiiModel.balanced.rawValue && call.prompt.contains("First item"))
        #expect(host.function("__ID__.summary") != nil)
    }

    @Test func widgetLoadsThroughItsProvider() async throws {
        let (feature, host) = try make()
        await feature.refresh()
        let loader = WidgetSnapshotLoader(provider: MainProvider(host: host))
        await loader.load(.init(limit: 1))
        #expect(loader.snapshot?.items.map(\\.title) == ["First item"])
        #expect(MainWidget.kind == "__ID__.main" && WidgetType(MainWidget.self).preview != nil)
    }

    @Test func statementsMapToTools() {
        let feature = __NAME__Feature()
        #expect(Set(feature.verbs.map(\\.tool)).isSubset(of: Set(feature.tools.map(\\.name))))
    }
}
"""

rules_test = """import DashKit
import Foundation
import Testing

/// Every extension of the plugin gives Dashii default rules, shipped as Rules/<id>.md.
@MainActor
struct DefaultRulesTests {
    @Test func everyExtensionHasRules() {
        for item in __NAME__Plugin.makeExtensions() {
            #expect(item.defaultRules?.isEmpty == false, "\\(item.id) has no default rules")
            #expect(RulesFile.load(id: item.id, bundle: Bundle(for: type(of: item))) == item.defaultRules)
        }
    }
}
"""

plugin_json = {
    "name": name,
    "kind": "integration" if args.integration else "feature",
    "icon": "link" if args.integration else "sparkles",
    "description": f"Connects your {name} account." if args.integration else f"Describe what {name} does.",
    "provides": [plugin_id],
    "author": {"name": author_name, **({"email": author_email} if author_email else {})},
}
if requires:
    plugin_json["requires"] = requires

info_plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>DashKitMinimumVersion</key>
	<string>2.0.0</string>
	<key>DashPluginID</key>
	<string>__ID__</string>
	<key>DashPluginVersion</key>
	<string>1.0.0</string>
</dict>
</plist>
"""

files = {
    "project.yml": project,
    "Info.plist": info_plist,
    "plugin.json": json.dumps(plugin_json, indent=2) + "\n",
    f"Sources/{name}Plugin.swift": entry,
    "Tests/DefaultRulesTests.swift": rules_test,
}
if args.integration:
    files.update({
        f"Sources/{name}Integration.swift": integration,
        f"Sources/Tools/{name}Tools.swift": integration_tools,
        f"Rules/{plugin_id}.md": integration_rules,
        f"Tests/{name}IntegrationTests.swift": integration_tests,
    })
else:
    files.update({
        f"Sources/{name}Feature.swift": feature,
        f"Sources/Tools/{name}Tools.swift": feature_tools,
        f"Sources/Query/{name}Query.swift": feature_query,
        "Sources/Widgets/Main/MainWidget.swift": widget,
        "Sources/Widgets/Main/MainProvider.swift": provider,
        "Sources/Widgets/Main/MainSnapshot.swift": snapshot,
        "Sources/Widgets/Main/MainView.swift": view,
        f"Rules/{plugin_id}.md": feature_rules,
        f"Tests/{name}FeatureTests.swift": feature_tests,
    })

for path, text in files.items():
    target = folder / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(fill(text))

print(f"Created plugins/{name} ({plugin_json['kind']} \"{plugin_id}\").")
print(f"Next: TEST=1 scripts/build-plugins.sh {name}")
print(f"Try it live: copy build/{name}/Build/Products/Release/{name}Plugin.dashplugin into")
print("  ~/Library/Application Support/Dash/Plugins (Dash asks to load it).")
