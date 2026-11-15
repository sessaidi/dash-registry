import DashKit
import Foundation
import Testing

@Suite("YAML subset")
struct YAMLTests {
    @Test func nestedMappingsAndScalars() throws {
        let value = try YAML.parse("""
            a: 1
            b:
              c: hello world
              d: "quoted: # not a comment"
              e: 'it''s'
            f: true
            g: ~
            h:
            i: https://1.2.3.4:443 # trailing comment
            j: 0123
            k: -42
            """)
        #expect(value["a"] == 1)
        #expect(value["b"]?["c"] == "hello world")
        #expect(value["b"]?["d"] == "quoted: # not a comment")
        #expect(value["b"]?["e"] == "it's")
        #expect(value["f"] == true)
        #expect(value["g"] == .null)
        #expect(value["h"] == .null)
        #expect(value["i"] == "https://1.2.3.4:443")
        #expect(value["j"] == "0123")
        #expect(value["k"] == -42)
    }

    @Test func sequencesAtSameIndentAsKey() throws {
        let value = try YAML.parse("""
            items:
            - name: one
              value: 1
            - name: two
              nested:
                deep: yes
            - plain
            - - inner
              - list
            after: x
            """)
        let items = try #require(value["items"]?.array)
        #expect(items.count == 4)
        #expect(items[0] == ["name": "one", "value": 1])
        #expect(items[1]["nested"]?["deep"] == "yes")
        #expect(items[2] == "plain")
        #expect(items[3] == ["inner", "list"])
        #expect(value["after"] == "x")
    }

    @Test func indentedSequences() throws {
        let value = try YAML.parse("""
            list:
              - a
              - b: c
                d: e
            """)
        #expect(value["list"] == ["a", ["b": "c", "d": "e"]])
    }

    @Test func flowCollections() throws {
        let value = try YAML.parse("""
            empty: {}
            none: []
            list: [a, "b, c", 3]
            map: {cluster: dev, user: sa, port: 8443, url: "https://x:1"}
            """)
        #expect(value["empty"] == .object([:]))
        #expect(value["none"] == .array([]))
        #expect(value["list"] == ["a", "b, c", 3])
        #expect(value["map"] == ["cluster": "dev", "user": "sa", "port": 8443, "url": "https://x:1"])
    }

    @Test func doubleQuotedEscapes() throws {
        let value = try YAML.parse(#"s: "tab\tnew\nquote\" slash\\ \u00e9""#)
        #expect(value["s"] == "tab\tnew\nquote\" slash\\ é")
    }

    @Test func blockScalars() throws {
        let value = try YAML.parse("""
            literal: |
              line one
                indented
              # not a comment
            stripped: |-
              no newline
            folded: >
              folded
              text

              para
            next: done
            """)
        #expect(value["literal"] == "line one\n  indented\n# not a comment\n")
        #expect(value["stripped"] == "no newline")
        #expect(value["folded"] == "folded text\npara\n")
        #expect(value["next"] == "done")
    }

    @Test func multiLinePlainScalar() throws {
        let value = try YAML.parse("""
            hint: Install the plugin by following
              https://example.com/docs#install
            other: x
            """)
        #expect(value["hint"] == "Install the plugin by following https://example.com/docs#install")
        #expect(value["other"] == "x")
    }

    @Test func documentMarkersCommentsAndCRLF() throws {
        let value = try YAML.parse("# header\r\n---\r\nkey: value\r\n\r\n# end\r\n")
        #expect(value == ["key": "value"])
    }

    @Test func quotedKeys() throws {
        let value = try YAML.parse("\"a b\": 1\n'c:d': 2")
        #expect(value == ["a b": 1, "c:d": 2])
    }

    @Test func emptyDocumentIsNull() throws {
        #expect(try YAML.parse("") == .null)
        #expect(try YAML.parse("# only a comment\n") == .null)
    }

    @Test func errorsReportLines() {
        #expect(throws: YAML.ParseError.self) { try YAML.parse("a: 1\n  b: 2") }
        #expect(throws: YAML.ParseError.self) { try YAML.parse("a: [1, 2") }
        #expect(throws: YAML.ParseError.self) { try YAML.parse("a: &anchor x") }
        #expect(throws: YAML.ParseError.self) { try YAML.parse("a:\n\tb: 1") }
        do {
            _ = try YAML.parse("a: 1\nb: \"unterminated")
            Issue.record("expected an error")
        } catch let error as YAML.ParseError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func scalarText() {
        #expect(JSONValue.number(8443).scalarText == "8443")
        #expect(JSONValue.bool(true).scalarText == "true")
        #expect(JSONValue.string("x").scalarText == "x")
        #expect(JSONValue.string("TRUE").flag)
        #expect(!JSONValue.null.flag)
    }
}
