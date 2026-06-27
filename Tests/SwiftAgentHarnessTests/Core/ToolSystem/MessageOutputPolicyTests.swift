import Testing
@testable import SwiftAgentHarness

@Suite("MessageOutputPolicy")
struct MessageOutputPolicyTests {
    @Test("nil or empty surface uses legacy streaming")
    func nilSurfaceLegacy() {
        #expect(MessageOutputPolicyResolver.policy(originSurface: nil) == .legacyStreamedText)
        #expect(MessageOutputPolicyResolver.policy(originSurface: "") == .legacyStreamedText)
    }

    @Test("channel surfaces always use message tool only")
    func channelSurfaces() {
        #expect(MessageOutputPolicyResolver.policy(originSurface: "slack") == .messageToolOnly)
        #expect(MessageOutputPolicyResolver.policy(originSurface: "telegram") == .messageToolOnly)
    }

    @Test("interactive surfaces default to message tool only")
    func interactiveDefaultMessageToolOnly() {
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: InteractiveSurfaceID.tui)
                == .messageToolOnly
        )
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: InteractiveSurfaceID.rest)
                == .messageToolOnly
        )
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: InteractiveSurfaceID.cli)
                == .messageToolOnly
        )
    }

    @Test("legacyStreamedTextSurfaces opts specific surfaces out")
    func interactiveOptOut() {
        let optOut: Set<String> = [InteractiveSurfaceID.cli]
        #expect(
            MessageOutputPolicyResolver.policy(
                originSurface: InteractiveSurfaceID.tui,
                legacyStreamedTextSurfaces: optOut
            ) == .messageToolOnly
        )
        #expect(
            MessageOutputPolicyResolver.policy(
                originSurface: InteractiveSurfaceID.cli,
                legacyStreamedTextSurfaces: optOut
            ) == .legacyStreamedText
        )
    }

    @Test("unknown surface defaults to message tool only")
    func unknownSurfaceMessageToolOnly() {
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: "custom-client") == .messageToolOnly
        )
    }
}

@Suite("MessageOutputTurnConfiguration")
struct MessageOutputTurnConfigurationTests {
    @Test("REST send sets originSurface and guidance by default")
    func restSendProvenance() {
        let configuration = MessageOutputTurnConfiguration.forRESTSend(
            enableTools: true,
            enableAgents: true,
            expectedPreviousTailHarnessMessageID: nil,
            inputTrustRaw: nil,
            resolvedInputTrustClass: nil
        )
        #expect(configuration.originSurface == InteractiveSurfaceID.rest)
        #expect(configuration.ephemeralSystemReminder?.contains("Output contract:") == true)
    }

    @Test("REST send skips guidance when surface opts out")
    func restSendLegacyOptOut() {
        let harness = AgentHarnessConfiguration(
            strictAgentHarnessPrompts: true,
            maxTurnLoopContinuationRounds: 1,
            planExcerptMaxCharacters: 100,
            watchdogEveryNContinuations: 0,
            maxConsecutiveChattyAssistantTurns: 1,
            repeatToolCallStreakThreshold: 2,
            maxAgenticStepsPerUpdate: nil,
            agentBuildToolInvocationPolicy: .automatic,
            rejectAssistantTurnWithNoToolCallsWhenToolsAvailable: false,
            maxCorrectionRetries: 0,
            legacyStreamedTextSurfaces: [InteractiveSurfaceID.rest]
        )
        let configuration = MessageOutputTurnConfiguration.forRESTSend(
            enableTools: true,
            enableAgents: true,
            expectedPreviousTailHarnessMessageID: nil,
            inputTrustRaw: nil,
            resolvedInputTrustClass: nil,
            harness: harness
        )
        #expect(configuration.originSurface == InteractiveSurfaceID.rest)
        #expect(configuration.ephemeralSystemReminder == nil)
    }

    @Test("ComposerSubmission builds TUI runtime configuration")
    func composerSubmissionConfiguration() {
        let submission = ComposerSubmission(
            text: "hi",
            provenance: ComposerProvenance(originSurface: InteractiveSurfaceID.tui)
        )
        let configuration = submission.runtimeTurnConfiguration()
        #expect(configuration.originSurface == InteractiveSurfaceID.tui)
        #expect(configuration.ephemeralSystemReminder?.contains("message") == true)
    }

    @Test("CLI send sets originSurface and guidance by default")
    func cliSendProvenance() {
        let configuration = MessageOutputTurnConfiguration.forCLISend()
        #expect(configuration.originSurface == InteractiveSurfaceID.cli)
        #expect(configuration.originSenderID == "*")
        #expect(configuration.ephemeralSystemReminder?.contains("Output contract:") == true)
    }

    @Test("applyingInteractiveDefaultsWhenMissing preserves explicit surface")
    func applyingDefaultsSkipsExplicitSurface() {
        let explicit = AgentRuntimeTurnConfiguration(originSurface: InteractiveSurfaceID.rest)
        let merged = MessageOutputTurnConfiguration.applyingInteractiveDefaultsWhenMissing(to: explicit)
        #expect(merged.originSurface == InteractiveSurfaceID.rest)
        #expect(merged.ephemeralSystemReminder == nil)
    }

    @Test("applyingInteractiveDefaultsWhenMissing applies CLI when unset")
    func applyingDefaultsUsesCLI() {
        let merged = MessageOutputTurnConfiguration.applyingInteractiveDefaultsWhenMissing(
            to: AgentRuntimeTurnConfiguration(enableTools: true)
        )
        #expect(merged.originSurface == InteractiveSurfaceID.cli)
        #expect(merged.ephemeralSystemReminder?.contains("Output contract:") == true)
    }
}

@Suite("MessageOutputSystemPromptGuidance")
struct MessageOutputSystemPromptGuidanceTests {
    @Test("mergedReminder preserves existing text and appends guidance")
    func mergedReminder() {
        let merged = MessageOutputSystemPromptGuidance.mergedReminder(
            existing: "prior context",
            policy: .messageToolOnly
        )
        #expect(merged?.contains("prior context") == true)
        #expect(merged?.contains("Output contract:") == true)
    }

    @Test("legacy policy leaves reminder unchanged")
    func legacyLeavesReminder() {
        #expect(
            MessageOutputSystemPromptGuidance.mergedReminder(
                existing: "keep",
                policy: .legacyStreamedText
            ) == "keep"
        )
    }
}
