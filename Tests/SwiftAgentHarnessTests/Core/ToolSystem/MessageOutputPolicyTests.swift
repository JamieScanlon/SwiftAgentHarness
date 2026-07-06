import Testing
@testable import SwiftAgentHarness

@Suite("MessageOutputPolicy")
struct MessageOutputPolicyTests {
    @Test("nil or empty surface uses streamed prose")
    func nilSurfaceStreamedProse() {
        #expect(MessageOutputPolicyResolver.policy(originSurface: nil) == .streamedProse)
        #expect(MessageOutputPolicyResolver.policy(originSurface: "") == .streamedProse)
    }

    @Test("channel surfaces use structured preferred guidance")
    func channelSurfaces() {
        #expect(MessageOutputPolicyResolver.policy(originSurface: "slack") == .structuredPreferred)
        #expect(MessageOutputPolicyResolver.policy(originSurface: "telegram") == .structuredPreferred)
    }

    @Test("interactive surfaces use structured preferred guidance")
    func interactiveStructuredPreferred() {
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: InteractiveSurfaceID.tui)
                == .structuredPreferred
        )
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: InteractiveSurfaceID.rest)
                == .structuredPreferred
        )
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: InteractiveSurfaceID.cli)
                == .structuredPreferred
        )
    }

    @Test("legacyStreamedTextSurfaces is deprecated and ignored")
    func legacyOptOutIgnored() {
        let optOut: Set<String> = [InteractiveSurfaceID.cli]
        #expect(
            MessageOutputPolicyResolver.policy(
                originSurface: InteractiveSurfaceID.tui,
                legacyStreamedTextSurfaces: optOut
            ) == .structuredPreferred
        )
        #expect(
            MessageOutputPolicyResolver.policy(
                originSurface: InteractiveSurfaceID.cli,
                legacyStreamedTextSurfaces: optOut
            ) == .structuredPreferred
        )
    }

    @Test("unknown surface uses structured preferred guidance")
    func unknownSurfaceStructuredPreferred() {
        #expect(
            MessageOutputPolicyResolver.policy(originSurface: "custom-client") == .structuredPreferred
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
        #expect(configuration.ephemeralSystemReminder?.contains("normal text") == true)
    }

    @Test("REST send still injects guidance when legacyStreamedTextSurfaces is set")
    func restSendLegacyOptOutDeprecated() {
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
        #expect(configuration.ephemeralSystemReminder?.contains("Output contract:") == true)
    }

    @Test("CLI send stamps direct user entry trust")
    func cliSendTrustStamp() {
        let configuration = MessageOutputTurnConfiguration.forCLISend()
        #expect(configuration.inputTrustRaw == MessageInputTrust.directUserEntry.rawValue)
        #expect(configuration.resolvedInputTrustClass == .trusted)
    }

    @Test("ComposerSubmission builds TUI runtime configuration with trusted input")
    func composerSubmissionConfiguration() {
        let submission = ComposerSubmission(
            text: "hi",
            provenance: ComposerProvenance(originSurface: InteractiveSurfaceID.tui)
        )
        let configuration = submission.runtimeTurnConfiguration()
        #expect(configuration.originSurface == InteractiveSurfaceID.tui)
        #expect(configuration.inputTrustRaw == MessageInputTrust.directUserEntry.rawValue)
        #expect(configuration.resolvedInputTrustClass == .trusted)
        #expect(configuration.ephemeralSystemReminder?.contains("message") == true)
    }

    @Test("REST send does not auto-stamp trusted input")
    func restSendDoesNotAutoStampTrust() {
        let configuration = MessageOutputTurnConfiguration.forRESTSend(
            enableTools: true,
            enableAgents: true,
            expectedPreviousTailHarnessMessageID: nil,
            inputTrustRaw: nil,
            resolvedInputTrustClass: nil
        )
        #expect(configuration.inputTrustRaw == nil)
        #expect(configuration.resolvedInputTrustClass == nil)
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
            policy: .structuredPreferred
        )
        #expect(merged?.contains("prior context") == true)
        #expect(merged?.contains("Output contract:") == true)
    }

    @Test("streamed prose policy leaves reminder unchanged")
    func streamedProseLeavesReminder() {
        #expect(
            MessageOutputSystemPromptGuidance.mergedReminder(
                existing: "keep",
                policy: .streamedProse
            ) == "keep"
        )
    }
}
