import Foundation

/// Routes composer submissions through the control-input boundary.
public struct TUIControlInputBridge {
    public var registry: SlashCommandRegistry
    public var capabilities: ControlSurfaceCapabilities
    public var configuration: ControlInputClassifierConfiguration

    public init(
        registry: SlashCommandRegistry = .builtins(compactEnabled: true),
        capabilities: ControlSurfaceCapabilities = .terminal,
        configuration: ControlInputClassifierConfiguration = ControlInputClassifierConfiguration()
    ) {
        self.registry = registry
        self.capabilities = capabilities
        self.configuration = configuration
    }

    private var classifier: ControlInputClassifier {
        ControlInputClassifier(
            registry: registry,
            capabilities: capabilities,
            configuration: configuration
        )
    }

    public func classify(_ submission: ComposerSubmission, authorization: ControlInputAuthorization = ControlInputAuthorization()) -> ControlInputClassification {
        classifier.classify(input: submission.text, authorization: authorization)
    }

    public func turnConfigurationPatch(from classification: ControlInputClassification) -> ControlInputTurnConfigurationPatch? {
        switch classification {
        case .directiveOnly(let directives), .inlineHint(let directives, _):
            return classifier.turnConfigurationPatch(from: directives)
        default:
            return nil
        }
    }

    /// Builds a runtime turn configuration with TUI provenance and optional message-tool output guidance.
    public func runtimeTurnConfiguration(
        from submission: ComposerSubmission,
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.loadFromPromptConfigBundle()
    ) -> AgentRuntimeTurnConfiguration {
        var configuration = submission.runtimeTurnConfiguration(base: base, harness: harness)
        if let patch = turnConfigurationPatch(from: classify(submission)) {
            configuration.turnThinkingOverride = patch.turnThinkingOverride
            configuration.turnModelSlug = patch.turnModelSlug
        }
        return configuration
    }
}
