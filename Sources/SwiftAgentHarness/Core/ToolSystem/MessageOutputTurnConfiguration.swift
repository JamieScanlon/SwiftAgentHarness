import Foundation

enum MessageOutputTurnConfiguration {
    /// Builds a turn configuration for an interactive surface, merging output-verb guidance when policy requires it.
    static func forInteractiveSend(
        base: AgentRuntimeTurnConfiguration,
        originSurface: String,
        originSenderID: String? = nil,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        var configuration = base
        configuration.originSurface = originSurface
        if let originSenderID {
            configuration.originSenderID = originSenderID
        }
        let policy = MessageOutputPolicyResolver.policy(
            originSurface: originSurface,
            legacyStreamedTextSurfaces: harness.legacyStreamedTextSurfaces
        )
        configuration.ephemeralSystemReminder = MessageOutputSystemPromptGuidance.mergedReminder(
            existing: configuration.ephemeralSystemReminder,
            policy: policy
        )
        return configuration
    }

    /// REST append-message defaults.
    static func forRESTSend(
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        originSenderID: String? = nil,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        forInteractiveSend(
            base: AgentRuntimeTurnConfiguration(
                enableTools: enableTools,
                enableAgents: enableAgents,
                expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
                inputTrustRaw: inputTrustRaw,
                resolvedInputTrustClass: resolvedInputTrustClass
            ),
            originSurface: InteractiveSurfaceID.rest,
            originSenderID: originSenderID,
            harness: harness
        )
    }

    /// TUI hosts pass composer provenance through this helper.
    static func forTUISend(
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        originSenderID: String? = nil,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        forInteractiveSend(
            base: base,
            originSurface: InteractiveSurfaceID.tui,
            originSenderID: originSenderID,
            harness: harness
        )
    }

    /// CLI / internal harness sends without explicit surface provenance.
    static func forCLISend(
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        originSenderID: String? = nil,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        forInteractiveSend(
            base: base,
            originSurface: InteractiveSurfaceID.cli,
            originSenderID: originSenderID ?? "*",
            harness: harness
        )
    }

    /// Applies interactive surface provenance and output-verb guidance when `originSurface` is unset.
    static func applyingInteractiveDefaultsWhenMissing(
        to configuration: AgentRuntimeTurnConfiguration,
        defaultSurface: String = InteractiveSurfaceID.cli,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        guard configuration.originSurface == nil || configuration.originSurface?.isEmpty == true else {
            return configuration
        }
        return forInteractiveSend(
            base: configuration,
            originSurface: defaultSurface,
            originSenderID: configuration.originSenderID ?? "*",
            harness: harness
        )
    }
}

extension ComposerSubmission {
    /// Builds a runtime turn configuration with TUI provenance and optional message-tool output guidance.
    public func runtimeTurnConfiguration(
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        MessageOutputTurnConfiguration.forInteractiveSend(
            base: base,
            originSurface: provenance.originSurface,
            harness: harness
        )
    }
}
