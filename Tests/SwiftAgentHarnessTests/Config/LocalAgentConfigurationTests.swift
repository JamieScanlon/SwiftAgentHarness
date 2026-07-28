import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("LocalAgentConfiguration decode")
struct LocalAgentConfigurationTests {
    private func load(_ localAgents: [String: Any]) -> LocalAgentConfiguration {
        LocalAgentConfiguration.fromPromptConfigRoot(["localAgents": localAgents])
    }

    private var validEntry: [String: Any] {
        [
            "description": "In-process coding delegate for repo read/write and shell work.",
            "modeProfileId": "coding-agent",
            "modelRef": "qwen/qwen3-coder-30b",
        ]
    }

    // MARK: - Naming

    @Test("Config key slugifies into a delegate_-prefixed tool name")
    func slugifiesConfigKey() {
        #expect(LocalAgentToolNaming.delegateToolName(forConfigKey: "Coding Agent") == "delegate_coding_agent")
        #expect(LocalAgentToolNaming.delegateToolName(forConfigKey: "  Code   Reviewer  ") == "delegate_code_reviewer")
        #expect(LocalAgentToolNaming.delegateToolName(forConfigKey: "explore-v2") == "delegate_explore_v2")
    }

    @Test("An already-prefixed key is not double-prefixed")
    func doesNotDoublePrefix() {
        #expect(LocalAgentToolNaming.delegateToolName(forConfigKey: "delegate_researcher") == "delegate_researcher")
    }

    @Test("A key with no ASCII slug is rejected")
    func rejectsUnslugifiableKey() {
        #expect(LocalAgentToolNaming.delegateToolName(forConfigKey: "   ") == nil)
        #expect(LocalAgentToolNaming.delegateToolName(forConfigKey: "***") == nil)
    }

    // MARK: - Happy path

    @Test("A valid entry parses into a definition keyed by generated tool name")
    func parsesValidEntry() {
        let config = load(["Coding Agent": validEntry])
        #expect(config.diagnostics.isEmpty)
        let definition = config.definition(forToolName: "delegate_coding_agent")
        #expect(definition != nil)
        #expect(definition?.displayName == "Coding Agent")
        #expect(definition?.modeProfileID == "coding-agent")
        #expect(definition?.modelRef == "qwen/qwen3-coder-30b")
        #expect(definition?.toolsAllow == nil)
        #expect(definition?.longRunning == false)
        #expect(definition?.runTimeoutSeconds == LocalAgentConfiguration.defaultRunTimeoutSeconds)
        #expect(definition?.maxRecursionDepth == nil)
    }

    @Test("Optional fields are carried through")
    func parsesOptionalFields() {
        var entry = validEntry
        entry["toolsAllow"] = ["read_file", "bash"]
        entry["longRunning"] = true
        entry["runTimeoutSeconds"] = 90
        entry["maxRecursionDepth"] = 1
        let config = load(["Coding Agent": entry])
        let definition = config.definition(forToolName: "delegate_coding_agent")
        #expect(definition?.toolsAllow == ["read_file", "bash"])
        #expect(definition?.longRunning == true)
        #expect(definition?.runTimeoutSeconds == 90)
        #expect(definition?.maxRecursionDepth == 1)
    }

    @Test("Absent localAgents yields the empty configuration")
    func absentSectionIsEmpty() {
        let config = LocalAgentConfiguration.fromPromptConfigRoot([:])
        #expect(config.isEmpty)
        #expect(config.diagnostics.isEmpty)
    }

    @Test("Definitions are ordered deterministically by tool name")
    func definitionsAreSorted() {
        let config = load([
            "Zeta": validEntry,
            "Alpha": validEntry,
            "Mid": validEntry,
        ])
        #expect(config.definitions.map(\.toolName) == ["delegate_alpha", "delegate_mid", "delegate_zeta"])
    }

    // MARK: - Rejections (each must skip the entry, never widen it)

    @Test("Missing description is rejected")
    func rejectsMissingDescription() {
        var entry = validEntry
        entry["description"] = ""
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
        #expect(config.diagnostics.count == 1)
    }

    @Test("Missing modeProfileId is rejected")
    func rejectsMissingModeProfileID() {
        var entry = validEntry
        entry.removeValue(forKey: "modeProfileId")
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
    }

    @Test("Missing modelRef is rejected")
    func rejectsMissingModelRef() {
        var entry = validEntry
        entry.removeValue(forKey: "modelRef")
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
    }

    @Test("A non-array toolsAllow fails closed rather than widening to all tools")
    func rejectsNonArrayToolsAllow() {
        var entry = validEntry
        entry["toolsAllow"] = "read_file"
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
        #expect(config.diagnostics.first?.contains("toolsAllow") == true)
    }

    @Test("A toolsAllow array containing a non-string fails closed")
    func rejectsMalformedToolsAllowElement() {
        var entry = validEntry
        entry["toolsAllow"] = ["read_file", 7]
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
    }

    @Test("An empty toolsAllow array is preserved as a closed world")
    func preservesEmptyToolsAllow() {
        var entry = validEntry
        entry["toolsAllow"] = [String]()
        let config = load(["Coding Agent": entry])
        #expect(config.definition(forToolName: "delegate_coding_agent")?.toolsAllow == [])
    }

    @Test("A negative maxRecursionDepth is rejected")
    func rejectsNegativeDepth() {
        var entry = validEntry
        entry["maxRecursionDepth"] = -1
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
    }

    @Test("A non-positive runTimeoutSeconds is rejected")
    func rejectsNonPositiveTimeout() {
        var entry = validEntry
        entry["runTimeoutSeconds"] = 0
        let config = load(["Coding Agent": entry])
        #expect(config.isEmpty)
    }

    @Test("runTimeoutSeconds is clamped to the maximum")
    func clampsTimeout() {
        var entry = validEntry
        entry["runTimeoutSeconds"] = 99_999
        let config = load(["Coding Agent": entry])
        #expect(
            config.definition(forToolName: "delegate_coding_agent")?.runTimeoutSeconds
                == LocalAgentConfiguration.maximumRunTimeoutSeconds
        )
    }

    @Test("A non-object entry is rejected")
    func rejectsNonObjectEntry() {
        let config = load(["Coding Agent": "nope"])
        #expect(config.isEmpty)
    }

    @Test("Colliding slugs keep the first key in sorted order and diagnose the loser")
    func rejectsSlugCollision() {
        let config = load([
            "Coding Agent": validEntry,
            "coding agent": validEntry,
            "Coding-Agent": validEntry,
        ])
        #expect(config.definitionsByToolName.count == 1)
        #expect(config.definition(forToolName: "delegate_coding_agent")?.displayName == "Coding Agent")
        #expect(config.diagnostics.count == 2)
    }

    @Test("One malformed entry does not suppress a sibling")
    func skipsOnlyTheMalformedEntry() {
        var broken = validEntry
        broken.removeValue(forKey: "modelRef")
        let config = load([
            "Coding Agent": validEntry,
            "Broken Agent": broken,
        ])
        #expect(config.definitionsByToolName.count == 1)
        #expect(config.definition(forToolName: "delegate_coding_agent") != nil)
        #expect(config.diagnostics.count == 1)
    }

    // MARK: - Document wiring

    @Test("localAgents is a known top-level PromptConfig key")
    func isKnownTopLevelKey() {
        #expect(PromptConfigDocument.knownTopLevelKeys.contains("localAgents"))
    }

    @Test("Loading through a parsed document produces the same definitions")
    func loadsFromDocument() throws {
        let json = """
        {
          "localAgents": {
            "Coding Agent": {
              "description": "In-process coding delegate.",
              "modeProfileId": "coding-agent",
              "modelRef": "qwen/qwen3-coder-30b",
              "longRunning": false
            }
          }
        }
        """
        let document = try PromptConfigDocument.parse(data: Data(json.utf8))
        #expect(document.unknownTopLevelKeys.isEmpty)
        let config = LocalAgentConfiguration.load(from: document)
        #expect(config.definition(forToolName: "delegate_coding_agent")?.displayName == "Coding Agent")
    }

    @Test("HarnessConfigurationSet exposes the section and defaults it to empty")
    func exposedOnConfigurationSet() {
        #expect(HarnessConfigurationSet.lockedDownBaseline.localAgents.isEmpty)
        let built = HarnessConfigurationSet.Builder()
            .withLocalAgents(
                LocalAgentConfiguration(definitionsByToolName: [
                    "delegate_coding_agent": LocalAgentDefinition(
                        toolName: "delegate_coding_agent",
                        displayName: "Coding Agent",
                        description: "In-process coding delegate.",
                        modeProfileID: "coding-agent",
                        modelRef: "qwen/qwen3-coder-30b"
                    ),
                ])
            )
            .build()
        #expect(built.localAgents.definitions.count == 1)
    }
}
