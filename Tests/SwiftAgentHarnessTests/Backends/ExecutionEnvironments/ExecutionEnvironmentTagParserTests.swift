import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Execution environment tag parser")
struct ExecutionEnvironmentTagParserTests {
    @Test("adapter ID case preserved from original tag")
    func adapterIDCasePreserved() {
        let raw = "execution.environment.adapter:Tool-Env.MCP"
        let value = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: raw,
            prefixes: [ExecutionEnvironmentTagParser.adapterPrefix]
        )
        #expect(value == "Tool-Env.MCP")
    }

    @Test("legacy adapter alias extracts with correct prefix length")
    func legacyAdapterAlias() {
        let raw = "executionenvironmentadapterid:tool-env.mcp.review"
        let value = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: raw,
            prefixes: [ExecutionEnvironmentTagParser.adapterLegacyPrefix]
        )
        #expect(value == "tool-env.mcp.review")
    }

    @Test("kind tag extracts canonical and legacy prefixes")
    func kindTagExtraction() {
        let canonical = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: "execution.environment.kind:mcp",
            prefixes: [ExecutionEnvironmentTagParser.kindPrefix, ExecutionEnvironmentTagParser.kindLegacyPrefix]
        )
        let legacy = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: "executionenvironmentkind:local",
            prefixes: [ExecutionEnvironmentTagParser.kindPrefix, ExecutionEnvironmentTagParser.kindLegacyPrefix]
        )
        #expect(canonical == "mcp")
        #expect(legacy == "local")
    }

    @Test("isolation tag extracts canonical prefix")
    func isolationTagExtraction() {
        let value = ExecutionEnvironmentTagParser.extractTaggedValue(
            raw: "execution.environment.isolation:remote-managed",
            prefixes: [ExecutionEnvironmentTagParser.isolationPrefix, ExecutionEnvironmentTagParser.isolationLegacyPrefix]
        )
        #expect(value == "remote-managed")
    }

    @Test("prefix length regression uses matched prefix byte length")
    func prefixLengthRegression() {
        let prefixes = [ExecutionEnvironmentTagParser.adapterPrefix, ExecutionEnvironmentTagParser.adapterLegacyPrefix]
        let mixedCase = "Execution.Environment.Adapter:MyAdapter"
        let value = ExecutionEnvironmentTagParser.extractTaggedValue(raw: mixedCase, prefixes: prefixes)
        #expect(value == "MyAdapter")
    }
}
