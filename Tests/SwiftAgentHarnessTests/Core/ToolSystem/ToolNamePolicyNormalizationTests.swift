import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ToolNamePolicyNormalization")
struct ToolNamePolicyNormalizationTests {
    @Test("normalizeToken trims and lowercases")
    func normalizeToken() {
        #expect(ToolNamePolicyNormalization.normalizeToken("  Bash  ") == "bash")
        #expect(ToolNamePolicyNormalization.normalizeToken("*") == "*")
        #expect(ToolNamePolicyNormalization.normalizeToken("  *  ") == "*")
    }

    @Test("canonical resolves legacy aliases")
    func canonicalLegacyAliases() {
        #expect(ToolNamePolicyNormalization.canonical("read") == "read_file")
        #expect(ToolNamePolicyNormalization.canonical("READ") == "read_file")
        #expect(ToolNamePolicyNormalization.canonical("terminal") == "bash")
        #expect(ToolNamePolicyNormalization.canonical("execute_command") == "bash")
        #expect(ToolNamePolicyNormalization.canonical("search_files") == "grep")
        #expect(ToolNamePolicyNormalization.canonical("web-search") == "web_search")
        #expect(ToolNamePolicyNormalization.canonical("fetch") == "web_fetch")
        #expect(ToolNamePolicyNormalization.canonical("grep") == "grep")
    }

    @Test("listContains is case-insensitive and resolves legacy names")
    func listContains() {
        let deny = ["filesystem_write", "terminal"]
        #expect(ToolNamePolicyNormalization.listContains(deny, name: "Filesystem_Write"))
        #expect(ToolNamePolicyNormalization.listContains(deny, name: "bash"))
        #expect(ToolNamePolicyNormalization.listContains(deny, name: "read_file") == false)
    }

    @Test("listContains honors wildcard")
    func listContainsWildcard() {
        #expect(ToolNamePolicyNormalization.listContains(["*"], name: "anything"))
        #expect(ToolNamePolicyNormalization.listContains([], name: "anything") == false)
    }

    @Test("setContains matches canonical forms")
    func setContains() {
        let sensitive: Set<String> = ["Bash", "read"]
        #expect(ToolNamePolicyNormalization.setContains(sensitive, name: "bash"))
        #expect(ToolNamePolicyNormalization.setContains(sensitive, name: "read_file"))
    }

    @Test("matchesRegistryName compares canonical forms")
    func matchesRegistryName() {
        #expect(ToolNamePolicyNormalization.matchesRegistryName(callName: "Finish", entryName: "finish"))
        #expect(ToolNamePolicyNormalization.matchesRegistryName(callName: "read", entryName: "read_file"))
    }
}
