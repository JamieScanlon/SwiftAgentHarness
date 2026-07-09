import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyArgumentExtractor")
struct ToolPolicyArgumentExtractorTests {
    @Test("bash command segments split on &&")
    func bashChain() {
        let args: JSON = .object(["command": .string("npm run test && rm -rf /")])
        let segments = ToolPolicyArgumentExtractor.extractedValues(toolName: "bash", arguments: args)
        #expect(segments.count == 2)
        #expect(segments[0] == "npm run test")
        #expect(segments[1] == "rm -rf /")
    }

    @Test("read_file path canonicalization")
    func pathCanonicalization() {
        let args: JSON = .object(["path": .string("/tmp/../etc/passwd")])
        let values = ToolPolicyArgumentExtractor.extractedValues(toolName: "read_file", arguments: args)
        #expect(values.count == 1)
        #expect(values[0].contains("passwd"))
    }
}

@Suite("ToolPolicyCallMatcher")
struct ToolPolicyCallMatcherTests {
    private func bashEntry() -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local
        )
    }

    @Test("bash npm run * matches npm run test")
    func bashPattern() {
        let rule = ToolPolicyRule.argumentMatcher(toolName: "bash", pattern: "npm run *")
        let entry = bashEntry()
        let args: JSON = .object(["command": .string("npm run test")])
        #expect(ToolPolicyCallMatcher.matches(rule: rule, entry: entry, arguments: args, groupIndex: .empty))
    }

    @Test("chain requires all segments to match")
    func chainAllMustPass() {
        let rule = ToolPolicyRule.argumentMatcher(toolName: "bash", pattern: "npm run *")
        let entry = bashEntry()
        let args: JSON = .object(["command": .string("npm run test && rm -rf /")])
        #expect(ToolPolicyCallMatcher.matches(rule: rule, entry: entry, arguments: args, groupIndex: .empty) == false)
    }
}

@Suite("ToolPolicyGatingEvaluator")
struct ToolPolicyGatingEvaluatorTests {
    private func bashEntry() -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local
        )
    }

    @Test("durable rule auto-allows matching call")
    func durableAutoAllow() {
        let entry = bashEntry()
        let args: JSON = .object(["command": .string("npm run test")])
        let rule = ToolPolicyRule.argumentMatcher(toolName: "bash", pattern: "npm run test")
        let decision = ToolPolicyGatingEvaluator.evaluate(
            entry: entry,
            arguments: args,
            groupIndex: .empty,
            scopes: [ToolPolicyGatingScope(name: "durable", autoAllowRules: [rule])]
        )
        #expect(decision.behavior == .allow)
    }

    @Test("deny-wins over durable allow")
    func denyWins() {
        let entry = bashEntry()
        let args: JSON = .object(["command": .string("npm run test")])
        let allow = ToolPolicyRule.argumentMatcher(toolName: "bash", pattern: "npm run test")
        let deny = ToolPolicyRule.bareName("bash")
        let decision = ToolPolicyGatingEvaluator.evaluate(
            entry: entry,
            arguments: args,
            groupIndex: .empty,
            scopes: [
                ToolPolicyGatingScope(name: "deny", denyRules: [deny]),
                ToolPolicyGatingScope(name: "durable", autoAllowRules: [allow]),
            ]
        )
        #expect(decision.behavior == .deny)
    }
}
