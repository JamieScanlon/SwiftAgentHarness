import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Mode profile computer-use policy")
struct ModeProfileComputerUseTests {
    private static func strictParent() -> ModeProfileConfiguration.RawProfile {
        ModeProfileConfiguration.RawProfile(
            id: "careful-agent",
            extends: "agent",
            subAgents: .object([
                "computerUse": .object(["confirmInteract": .boolean(true)]),
            ])
        )
    }

    @Test("Built-in modes leave computer use to its own gating")
    func builtInsDefault() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: .empty)
        for id in ["agent", "chat", "plan"] {
            #expect(try await registry.resolve(modeId: id).subAgents.computerUse == .neutral)
        }
    }

    @Test("A profile can require confirming every Interact action, and profiles extending it inherit that")
    func confirmInteractParsesAndInherits() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                Self.strictParent(),
                ModeProfileConfiguration.RawProfile(
                    id: "careful-research",
                    extends: "careful-agent",
                    subAgents: .object(["maxDepth": .integer(1)])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        #expect(try await registry.resolve(modeId: "careful-agent").subAgents.computerUse.confirmsInteract)
        let child = try await registry.resolve(modeId: "careful-research")
        #expect(child.subAgents.computerUse.confirmsInteract)
        #expect(child.subAgents.maxDepth == 1)
    }

    @Test("A profile can't loosen what the profile it extends requires")
    func cannotLoosen() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                Self.strictParent(),
                ModeProfileConfiguration.RawProfile(
                    id: "loose",
                    extends: "careful-agent",
                    subAgents: .object([
                        "computerUse": .object(["confirmInteract": .boolean(false)]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        #expect(try await registry.resolve(modeId: "loose").subAgents.computerUse.confirmsInteract)
        let diagnostics = await registry.configurationDiagnostics()
        #expect(diagnostics.contains { $0.contains("modeProfiles[loose]") && $0.contains("subAgents.computerUse.confirmInteract") })
    }

    @Test("The policy is read from PromptConfig JSON")
    func loadsFromJSON() async throws {
        let json = #"{"modeProfiles": [{"id": "careful", "extends": "agent", "subAgents": {"computerUse": {"confirmInteract": true}}}]}"#
        let config = ModeProfileConfiguration.load(from: try PromptConfigDocument.parse(data: Data(json.utf8)))
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        #expect(try await registry.resolve(modeId: "careful").subAgents.computerUse.confirmsInteract)
    }

    @Test("Machine sub-agent profiles stay neutral")
    func computerUseSpecialistProfile() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: .empty)
        #expect(try await registry.resolve(modeId: "subagent-computer-use").subAgents.computerUse == .neutral)
    }
}
