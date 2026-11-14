#!/usr/bin/env python3
"""Creates a new Dash plugin under plugins/<Name>: a buildable, tested starting point.

    scripts/new-plugin.py Weather --feature
    scripts/new-plugin.py Linear --integration --author "Ada <ada@example.com>"
    scripts/new-plugin.py Standup --feature --requires atlassian,github

An integration holds an account (token in the Keychain, an authenticated connection, a status).
A feature adds a widget (with a sample-data preview), a Claude tool and an AI task, and uses
integrations only through DashKit. Build and test it with:

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

swift_author = f'ExtensionAuthor(name: "{author_name}"' + (f', email: "{author_email}")' if author_email else ")")
widget_kind = f"{plugin_id}.main"

project = f"""# A Dash plugin. Build, test, zip and index it with: TEST=1 scripts/build-plugins.sh {name}
name: {name}Plugin
options:
  deploymentTarget: {{ macOS: "26.0" }}
  createIntermediateGroups: true
packages:
  DashKit: {{ path: ../../../perso/dash/Packages/DashKit }}
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
targets:
  {name}Plugin:
    type: bundle
    platform: macOS
    sources:
      - Sources
      - path: plugin.json       # the bundle describes itself (Contents/Resources/plugin.json)
        buildPhase: resources
    dependencies:
      - package: DashKit
        product: DashKit
        embed: false            # Dash provides DashKit at runtime
    info:
      path: Info.plist
      properties:
        CFBundleExecutable: "$(EXECUTABLE_NAME)"
        NSPrincipalClass: {name}DashPlugin
        DashPluginID: {plugin_id}
        DashPluginVersion: "1.0.0"
        DashKitMinimumVersion: "1.0.0"
    settings:
      base:
        WRAPPER_EXTENSION: dashplugin
        PRODUCT_BUNDLE_IDENTIFIER: {args.bundle_prefix}.{plugin_id}
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks @loader_path/../../../../Frameworks"
    scheme: {{}}
  {name}PluginTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Sources, Tests]
    dependencies:
      - package: DashKit
        product: DashKit      # includes DashKitTesting
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: {args.bundle_prefix}.{plugin_id}.tests
    scheme:
      testTargets: [{name}PluginTests]
"""

entry = f"""import DashKit
import Foundation

/// The plugin's principal class (informational; Dash calls `dash_plugin_entry`).
@objc({name}DashPlugin)
final class {name}Plugin: DashPlugin {{
    override class func makeExtensions() -> [any DashExtension] {{ [{name}{"Integration" if args.integration else "Feature"}()] }}
}}

/// The entry point Dash loads: hands over this plugin's integrations and features.
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {{
    DashPluginFactory.export {{ {name}Plugin.makeExtensions() }}
}}
"""

integration = f"""import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The {name} account: an API token in the Keychain and an authenticated connection that
/// features use without seeing the token.
@MainActor
@Observable
final class {name}Integration: Integration {{
    let id = "{plugin_id}"
    let name = "{name}"
    let systemImage = "link"
    let metadata = ExtensionMetadata(version: "1.0.0", author: {swift_author},
                                     summary: "Connects your {name} account.", category: .other, minimumDashKit: "1.0.0")
    let secretKeys = [SecretKey("token", "API token")]
    let secrets: SecretStore? = SecretStore(extensionID: "{plugin_id}")

    /// The API every request goes to. Change it to the service's.
    static let apiURL = URL(string: "https://api.example.com")!

    @ObservationIgnored private let readToken: @MainActor () -> String?
    @ObservationIgnored private let session: URLSession?
    private(set) var account: String?
    private(set) var lastError: String?

    /// `token` and `session` are for tests; Dash uses the Keychain and the shared session.
    init(token: (@MainActor () -> String?)? = nil, session: URLSession? = nil) {{
        let store = SecretStore(extensionID: "{plugin_id}")
        readToken = token ?? {{ store.read("token") }}
        self.session = session
    }}

    private var token: String? {{ readToken().flatMap {{ $0.isEmpty ? nil : $0 }} }}
    var isConnected: Bool {{ token != nil }}
    var connectionState: ConnectionState {{ state(error: lastError, configured: isConnected, account: account) }}

    var connection: IntegrationConnection? {{
        guard let token else {{ return nil }}
        return IntegrationConnection(baseURL: Self.apiURL, headers: ["Authorization": "Bearer \\(token)"], session: session)
    }}

    /// What features may read without the secret (e.g. the signed-in account).
    var exports: JSONValue {{ ["account": account.map {{ .string($0) }} ?? .null] }}

    func start(host: any ExtensionContext) {{
        Task {{ await verify() }}
    }}

    /// Checks the token once at launch, while the splash screen shows progress.
    func prepare(host: any ExtensionContext) async throws {{
        await verify()
        if let lastError {{ throw ToolError(lastError) }}
    }}

    func setToken(_ token: String) {{
        secrets?.write("token", token)
        account = nil
        Task {{ await verify() }}
    }}

    /// Asks the API who the token belongs to. Adjust the path and field to the service's.
    func verify() async {{
        guard let connection else {{ lastError = nil; return }}
        do {{
            account = try await connection.get("/me", service: name)["name"]?.string
            lastError = nil
        }} catch {{
            lastError = error.localizedDescription
        }}
    }}

    func settingsView() -> AnyView {{ AnyView({name}Settings(integration: self)) }}

    var tools: [ClaudeTool] {{
        [ClaudeTool(name: "{plugin_id.replace("-", "_")}_get", description: "GET a {name} API path and return the JSON.",
                    properties: ["path": JSONSchema.string("API path, e.g. /me.")], required: ["path"]) {{ [weak self] input in
            guard let connection = self?.connection else {{ throw ToolError("Connect {name} in Settings.") }}
            return try await connection.get(input["path"]?.string ?? "/", service: "{name}")
        }}]
    }}
}}

private struct {name}Settings: View {{
    let integration: {name}Integration

    var body: some View {{
        Form {{
            Section {{
                SecretField("API token", isStored: integration.isConnected, onSave: {{ integration.setToken($0) }},
                            onRemove: {{ integration.setToken("") }})
                LabeledContent("Status") {{ ConnectionStatusLabel(integration.connectionState) }}
            }} footer: {{
                Text("Stored in your Keychain. Features use the connection; they never see the token.")
            }}
        }}
    }}
}}
"""

requires_swift = ", ".join(f'"{r}"' for r in requires)
feature = f"""import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// {name}: a widget, a Claude tool and an AI task.{" Uses " + ", ".join(requires) + " through DashKit only." if requires else ""}
@MainActor
@Observable
final class {name}Feature: DashExtension {{
    let id = "{plugin_id}"
    let name = "{name}"
    let systemImage = "sparkles"
    let metadata = ExtensionMetadata(version: "1.0.0", author: {swift_author},
                                     summary: "Describe what {name} does.", category: .productivity, minimumDashKit: "1.0.0")
    let requires: [String] = [{requires_swift}]

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    private(set) var items: [{name}Item] = []
    private(set) var lastError: String?

    var widgets: [WidgetType] {{ [WidgetType({name}Widget.self)] }}

    /// What the feature asks Claude; the user picks model, effort and the prompt in its AI tab.
    static let summarizeTask = AITask(
        id: "summarize", title: "Summaries", summary: "Summarizes the items for the dashboard.",
        models: [.haiku, .sonnet, .opus], efforts: [.low, .medium, .high],
        templates: [AITemplate(id: "prompt", title: "Prompt", defaultText: "Summarize these {{{{count}}}} items in two sentences.",
                               variables: ["count": "How many items"], multiline: true)])

    var aiTasks: [AITask] {{ [Self.summarizeTask] }}

    func start(host: any ExtensionContext) {{
        self.host = host
        Task {{ await refresh() }}
    }}

    /// Loads the items. Replace with real work (an integration's connection, a local API…).
    func refresh() async {{
        items = [{name}Item(title: "First item", detail: "Replace with real data"), {name}Item(title: "Second item", detail: "Up to date")]
        lastError = nil
        host?.activity.emit("{plugin_id}.refreshed", source: id, title: "{name} refreshed", importance: .info)
    }}

    func summarize() async throws -> String {{
        guard let host else {{ throw ToolError("{name} isn't running.") }}
        let settings = host.aiSettings(.extension(id), tasks: aiTasks)
        let prompt = settings.render(Self.summarizeTask.id, "prompt", ["count": String(items.count)])
        return try await host.claude.complete(task: Self.summarizeTask.id, settings: settings, system: "You are concise.",
                                              prompt: prompt + "\\n\\n" + items.map(\\.title).joined(separator: "\\n"))
    }}

    var tools: [ClaudeTool] {{
        [ClaudeTool(name: "{plugin_id.replace("-", "_")}_items", description: "List {name}'s items.") {{ [weak self] _ in
            .array((self?.items ?? []).map {{ ["title": .string($0.title), "detail": .string($0.detail)] }})
        }}]
    }}
}}

struct {name}Item: Identifiable, Hashable, Sendable {{
    var id: String {{ title }}
    let title: String
    let detail: String
}}

struct {name}Widget: DashboardWidget {{
    struct Config: Codable, Equatable, Sendable {{
        var limit: Int = 10
    }}

    static let kind = "{widget_kind}"
    static let displayName = "{name}"
    static let summary = "Describe what the widget shows."
    static let systemImage = "sparkles"
    static let defaultSize = WidgetSize.medium
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["limit": ["type": "integer", "description": "How many items to show."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {{
        if let feature = context.host.ext({name}Feature.self) {{
            {name}List(items: Array(feature.items.prefix(config.wrappedValue.limit)))
        }} else {{
            StateView(.failed(message: "{name} isn't loaded."))
        }}
    }}

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {{
        Stepper("Show \\(config.wrappedValue.limit) items", value: config.limit, in: 1...50)
    }}

    /// Sample data for the widget gallery: no network, no accounts.
    static func preview(config: Config) -> some View {{
        {name}List(items: [{name}Item(title: "Sample item", detail: "Shown in the gallery"), {name}Item(title: "Another", detail: "Sample data")])
    }}

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {{
        .array((context.host.ext({name}Feature.self)?.items ?? []).prefix(config.limit).map {{ ["title": .string($0.title)] }})
    }}
}}

private struct {name}List: View {{
    let items: [{name}Item]

    var body: some View {{
        if items.isEmpty {{
            StateView(.empty(title: "Nothing yet", systemImage: "tray", message: nil))
        }} else {{
            VStack(alignment: .leading, spacing: 8) {{
                ForEach(items) {{ item in
                    ItemRow(item.title, subtitle: item.detail, leading: {{ StatusDot(.success) }})
                }}
                Spacer(minLength: 0)
            }}
        }}
    }}
}}
"""

integration_tests = f"""import DashKit
import DashKitTesting
import Foundation
import Testing

@MainActor
struct {name}IntegrationTests {{
    @Test func connectsWithATokenAndVerifiesTheAccount() async throws {{
        let host = "api-\\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: ["/me": #"{{"name": "ada"}}"#])
        let integration = {name}Integration(token: {{ "secret" }}, session: StubHTTP.session)
        #expect(integration.isConnected)
        // Point the connection at the stub (the real one uses apiURL).
        var connection = try #require(integration.connection)
        connection = IntegrationConnection(baseURL: URL(string: "https://\\(host)")!, headers: connection.headers, session: StubHTTP.session)
        #expect(try await connection.get("/me", service: "test")["name"] == "ada")
        #expect(StubHTTP.requests(host).first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }}

    @Test func noTokenMeansNotConnected() {{
        let integration = {name}Integration(token: {{ nil }})
        #expect(!integration.isConnected && integration.connection == nil)
        #expect(integration.connectionState == .notConfigured)
    }}
}}
"""

feature_tests = f"""import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

@MainActor
struct {name}FeatureTests {{
    @Test func refreshesAndListsItems() async throws {{
        let feature = {name}Feature()
        let host = try TestHost([feature])
        host.start([feature])
        await feature.refresh()
        let items = try await host.runTool("{plugin_id.replace("-", "_")}_items")
        #expect(items?.array?.count == 2)
        #expect(host.activity.events.contains {{ $0.kind == "{plugin_id}.refreshed" }})
    }}

    @Test func summariesUseTheAITabChoices() async throws {{
        let feature = {name}Feature()
        let host = try TestHost([feature])
        host.start([feature])
        await feature.refresh()
        host.aiChoices[.extension(feature.id)] = ["summarize": AITaskChoice(model: .sonnet, templates: ["prompt": "Count: {{{{count}}}}"])]
        host.testClaude.reply = "All good."
        #expect(try await feature.summarize() == "All good.")
        let call = try #require(host.testClaude.calls.last)
        #expect(call.model == ClaudeModel.sonnet.rawValue && call.prompt.hasPrefix("Count: 2"))
    }}

    @Test func widgetContract() {{
        #expect({name}Widget.kind == "{widget_kind}")
        #expect({name}Widget.sizeLimits.minW == 3)
        let type = WidgetType({name}Widget.self)
        #expect(type.preview != nil)
    }}
}}
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
</dict>
</plist>
"""

(folder / "Sources").mkdir(parents=True)
(folder / "Tests").mkdir()
(folder / "project.yml").write_text(project)
(folder / "Info.plist").write_text(info_plist)
(folder / "plugin.json").write_text(json.dumps(plugin_json, indent=2) + "\n")
(folder / "Sources" / f"{name}Plugin.swift").write_text(entry)
if args.integration:
    (folder / "Sources" / f"{name}Integration.swift").write_text(integration)
    (folder / "Tests" / f"{name}IntegrationTests.swift").write_text(integration_tests)
else:
    (folder / "Sources" / f"{name}Feature.swift").write_text(feature)
    (folder / "Tests" / f"{name}FeatureTests.swift").write_text(feature_tests)

print(f"Created plugins/{name} ({plugin_json['kind']} \"{plugin_id}\").")
print(f"Next: TEST=1 scripts/build-plugins.sh {name}")
print(f"Try it live: copy build/{name}/Build/Products/Release/{name}Plugin.dashplugin into")
print("  ~/Library/Application Support/Dash/Plugins (Dash asks to load it).")
