import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyRuleParser")
struct ToolPolicyRuleParserTests {
    @Test("parses wildcard")
    func wildcard() throws {
        let rule = try ToolPolicyRuleParser.parse("*")
        #expect(rule == .wildcard)
    }

    @Test("parses bare tool name with canonicalization")
    func bareName() throws {
        let rule = try ToolPolicyRuleParser.parse("terminal")
        #expect(rule == .bareName("bash"))
        let read = try ToolPolicyRuleParser.parse("Read_File")
        #expect(read == .bareName("read_file"))
    }

    @Test("parses name glob without canonicalizing pattern")
    func nameGlob() throws {
        let rule = try ToolPolicyRuleParser.parse("mcp_*")
        #expect(rule == .nameGlob("mcp_*"))
        let web = try ToolPolicyRuleParser.parse("web_*")
        #expect(web == .nameGlob("web_*"))
    }

    @Test("parses group alias")
    func groupAlias() throws {
        let rule = try ToolPolicyRuleParser.parse("group:fs")
        #expect(rule == .groupAlias("fs"))
        let mcp = try ToolPolicyRuleParser.parse("GROUP:MCP")
        #expect(mcp == .groupAlias("mcp"))
        let plugin = try ToolPolicyRuleParser.parse("group:myPlugin")
        #expect(plugin == .groupAlias("myplugin"))
    }

    @Test("parses argument matcher")
    func argumentMatcher() throws {
        let rule = try ToolPolicyRuleParser.parse("bash(npm run *)")
        #expect(rule == .argumentMatcher(toolName: "bash", pattern: "npm run *"))
        let path = try ToolPolicyRuleParser.parse("read_file(/tmp/*)")
        #expect(path == .argumentMatcher(toolName: "read_file", pattern: "/tmp/*"))
    }

    @Test("parses escaped parentheses in argument pattern")
    func escapedParens() throws {
        let rule = try ToolPolicyRuleParser.parse(#"bash(echo \(hello\))"#)
        #expect(rule == .argumentMatcher(toolName: "bash", pattern: "echo (hello)"))
    }

    @Test("rejects malformed argument matcher")
    func malformedMatcher() {
        #expect(throws: ToolPolicyRuleParseError.self) {
            try ToolPolicyRuleParser.parse("bash(npm run *")
        }
        #expect(throws: ToolPolicyRuleParseError.self) {
            try ToolPolicyRuleParser.parse("(missing tool)")
        }
    }

    @Test("parseMany deduplicates and preserves wildcard collapse")
    func parseMany() throws {
        let rules = try ToolPolicyRuleParser.parseMany(["read_file", "read_file", "group:fs"])
        #expect(rules.count == 2)
        let wildcard = try ToolPolicyRuleParser.parseMany(["*", "read_file"])
        #expect(wildcard == [.wildcard])
    }

    @Test("rawToken round trip")
    func rawToken() throws {
        let samples: [(String, ToolPolicyRule)] = [
            ("*", .wildcard),
            ("bash", .bareName("bash")),
            ("mcp_*", .nameGlob("mcp_*")),
            ("group:fs", .groupAlias("fs")),
            ("bash(npm run *)", .argumentMatcher(toolName: "bash", pattern: "npm run *")),
        ]
        for (raw, rule) in samples {
            let parsed = try ToolPolicyRuleParser.parse(raw)
            #expect(parsed == rule)
            #expect(parsed.rawToken == raw || parsed.rawToken.lowercased() == raw.lowercased())
        }
    }
}
