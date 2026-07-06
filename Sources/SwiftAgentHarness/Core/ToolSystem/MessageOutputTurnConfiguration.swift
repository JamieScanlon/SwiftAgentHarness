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

    /// Stamps first-party interactive surfaces with direct-user-entry trust when input trust is omitted.
    static func applyingDirectUserEntryTrustWhenEligible(
        to configuration: AgentRuntimeTurnConfiguration
    ) -> AgentRuntimeTurnConfiguration {
        var out = configuration
        guard MessageInputTrustCodec.sanitizedInputTrustRaw(out.inputTrustRaw) == nil else {
            return out
        }
        guard let surface = out.originSurface,
              surface == InteractiveSurfaceID.tui || surface == InteractiveSurfaceID.cli else {
            return out
        }
        out.inputTrustRaw = MessageInputTrust.directUserEntry.rawValue
        out.resolvedInputTrustClass = .trusted
        return out
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
        applyingDirectUserEntryTrustWhenEligible(to: forInteractiveSend(
            base: base,
            originSurface: InteractiveSurfaceID.tui,
            originSenderID: originSenderID,
            harness: harness
        ))
    }

    /// CLI / internal harness sends without explicit surface provenance.
    static func forCLISend(
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        originSenderID: String? = nil,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        applyingDirectUserEntryTrustWhenEligible(to: forInteractiveSend(
            base: base,
            originSurface: InteractiveSurfaceID.cli,
            originSenderID: originSenderID ?? "*",
            harness: harness
        ))
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
        return applyingDirectUserEntryTrustWhenEligible(to: forInteractiveSend(
            base: configuration,
            originSurface: defaultSurface,
            originSenderID: configuration.originSenderID ?? "*",
            harness: harness
        ))
    }

    /// Applies interactive surface defaults and first-party trust stamping for runtime sends.
    static func applyingInteractiveSendDefaults(
        to configuration: AgentRuntimeTurnConfiguration,
        defaultSurface: String = InteractiveSurfaceID.cli,
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        applyingDirectUserEntryTrustWhenEligible(to: applyingInteractiveDefaultsWhenMissing(
            to: configuration,
            defaultSurface: defaultSurface,
            harness: harness
        ))
    }
}

extension ComposerSubmission {
    /// Resolves trust for control-input authorization using the same first-party stamping rules as runtime sends.
    public func resolvedInputTrustClassForControlInput() -> TrustPolicyClass {
        var configuration = AgentRuntimeTurnConfiguration(
            inputTrustRaw: MessageInputTrustCodec.sanitizedInputTrustRaw(provenance.inputTrustRaw),
            originSurface: provenance.originSurface
        )
        configuration = MessageOutputTurnConfiguration.applyingDirectUserEntryTrustWhenEligible(to: configuration)
        return configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(raw: configuration.inputTrustRaw)
    }

    /// Builds a runtime turn configuration with TUI provenance and optional message-tool output guidance.
    public func runtimeTurnConfiguration(
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        var baseWithProvenance = base
        baseWithProvenance.inputTrustRaw = MessageInputTrustCodec.sanitizedInputTrustRaw(provenance.inputTrustRaw)
        if baseWithProvenance.resolvedInputTrustClass == nil {
            baseWithProvenance.resolvedInputTrustClass = MessageInputTrustCodec.safePolicyClass(
                raw: baseWithProvenance.inputTrustRaw
            )
        }
        return MessageOutputTurnConfiguration.applyingDirectUserEntryTrustWhenEligible(to: MessageOutputTurnConfiguration.forInteractiveSend(
            base: baseWithProvenance,
            originSurface: provenance.originSurface,
            harness: harness
        ))
    }
}
