import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Delegate-completion resume policy")
struct DelegateCompletionResumePolicyTests {
    @Test("Unset on the profile reproduces the rule the knob replaced")
    func unsetFallsBackToInteractionMode() async throws {
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true)
        for mode in [InteractionMode.chat, .plan, .agent] {
            let profile = try await registry.resolve(modeId: mode.rawValue)
            // No built-in states the key, so every one of them must fall through to the fallback.
            #expect(profile.runtime.resumesOnDelegateCompletion == nil)
            #expect(
                OrchestratorSessionRuntimeService.resumesOnDelegateCompletion(
                    runtime: profile.runtime,
                    interactionMode: mode
                ) == (mode == .agent)
            )
        }
    }

    @Test("A chat-derived profile can opt in to waking on a delegate completion")
    func chatDerivedProfileCanOptIn() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "chat-with-delegates",
                    extends: InteractionMode.chat.rawValue,
                    runtime: .object([
                        "resumesOnDelegateCompletion": .boolean(true),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "chat-with-delegates")
        #expect(profile.interactionMode == .chat)
        #expect(profile.runtime.resumesOnDelegateCompletion == true)
        #expect(
            OrchestratorSessionRuntimeService.resumesOnDelegateCompletion(
                runtime: profile.runtime,
                interactionMode: profile.interactionMode
            ) == true
        )
    }

    @Test("An agent-derived profile can opt out of waking on a delegate completion")
    func agentDerivedProfileCanOptOut() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "agent-quiet-delegates",
                    extends: InteractionMode.agent.rawValue,
                    runtime: .object([
                        "resumesOnDelegateCompletion": .boolean(false),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "agent-quiet-delegates")
        #expect(profile.interactionMode == .agent)
        #expect(profile.runtime.resumesOnDelegateCompletion == false)
        // An explicit `false` must beat the agent-mode fallback, or the knob cannot turn anything off.
        #expect(
            OrchestratorSessionRuntimeService.resumesOnDelegateCompletion(
                runtime: profile.runtime,
                interactionMode: profile.interactionMode
            ) == false
        )
    }

    @Test("A child inherits the parent's opt-in without restating it")
    func optInIsInherited() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "chat-with-delegates",
                    extends: InteractionMode.chat.rawValue,
                    runtime: .object([
                        "resumesOnDelegateCompletion": .boolean(true),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "chat-with-delegates-narrowed",
                    extends: "chat-with-delegates",
                    tools: .object([
                        "deny": .array([.string("bash")]),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "chat-with-delegates-narrowed")
        #expect(profile.runtime.resumesOnDelegateCompletion == true)
    }

    @Test("A non-boolean value leaves the inherited decision alone")
    func nonBooleanValueIsRejected() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "chat-with-delegates",
                    extends: InteractionMode.chat.rawValue,
                    runtime: .object([
                        "resumesOnDelegateCompletion": .boolean(true),
                    ])
                ),
                ModeProfileConfiguration.RawProfile(
                    id: "chat-with-delegates-typo",
                    extends: "chat-with-delegates",
                    runtime: .object([
                        "resumesOnDelegateCompletion": .string("yes"),
                    ])
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "chat-with-delegates-typo")
        // Coercing `"yes"` to true would be guesswork, and clearing it to nil would silently drop
        // the parent's opt-in back to the agent-only fallback. Neither is what was written.
        #expect(profile.runtime.resumesOnDelegateCompletion == true)
    }

    @Test("A profile declaring agent mode without extending the built-in still wakes")
    func standaloneAgentModeProfileStillWakes() async throws {
        let config = ModeProfileConfiguration(
            profiles: [
                ModeProfileConfiguration.RawProfile(
                    id: "standalone-agent",
                    interactionMode: .agent,
                    assemblyKind: .agentBuild,
                    allowsProactiveCompactionTriggers: true,
                    appliesAgentBuildOrchestratorHarness: true,
                    semanticLayerTags: []
                ),
            ],
            diagnostics: []
        )
        let registry = ModeRegistryTestSupport.makeService(seedingBuiltIns: true, modeProfileConfiguration: config)
        let profile = try await registry.resolve(modeId: "standalone-agent")
        // This row inherits nothing, so only the interaction-mode fallback can carry it. Without
        // that fallback the knob would silently stop waking custom agent profiles.
        #expect(profile.runtime.resumesOnDelegateCompletion == nil)
        #expect(
            OrchestratorSessionRuntimeService.resumesOnDelegateCompletion(
                runtime: profile.runtime,
                interactionMode: profile.interactionMode
            ) == true
        )
    }
}
