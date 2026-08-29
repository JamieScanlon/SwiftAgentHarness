import Foundation

/// Surface-side control-input support: autocomplete data, provenance stamping, and a
/// local *presentation* classification.
///
/// Deliberately **not** a dispatch path. `SlashCommandDispatchService.processControlInputBoundary`
/// already runs inside `sendMessageAndStreamResponse`, where it can build a
/// conversation-scoped registry and derive a real authorization from the conversation
/// owner. Classifying here instead would duplicate a fragment of that with a static
/// registry and a default authorization — weaker on exactly the axis that matters — and
/// would miss `.command`, `.inlineShortcut` and the strip-before-model rule entirely.
///
/// The surface sends raw text; the boundary decides what it means.
public struct TUIControlInputBridge {
    /// Conversation-scoped when the host supplies one via
    /// ``TUIAppHost/slashCommandRegistry()``; the built-in set omits conversation-scoped
    /// commands and skills (`/skill:<name>`), so autocomplete silently under-reports
    /// without it.
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

    /// Presentation-only classification: use it to decide whether a line should be echoed
    /// into the transcript, never to decide what to dispatch.
    public func classify(
        _ submission: ComposerSubmission,
        authorization: ControlInputAuthorization? = nil
    ) -> ControlInputClassification {
        let resolvedAuthorization = authorization ?? Self.authorization(for: submission)
        return classifier.classify(input: submission.text, authorization: resolvedAuthorization)
    }

    private static func authorization(for submission: ComposerSubmission) -> ControlInputAuthorization {
        ControlInputAuthorization(
            trustClass: submission.resolvedInputTrustClassForControlInput()
        )
    }

    public func turnConfigurationPatch(from classification: ControlInputClassification) -> ControlInputTurnConfigurationPatch? {
        switch classification {
        case .directiveOnly(let directives), .inlineHint(let directives, _):
            return classifier.turnConfigurationPatch(from: directives)
        default:
            return nil
        }
    }

    /// Builds a runtime turn configuration carrying TUI provenance.
    ///
    /// Provenance stamping *is* a surface responsibility — the trust class it resolves
    /// feeds the authorization the core boundary then applies.
    public func runtimeTurnConfiguration(
        from submission: ComposerSubmission,
        base: AgentRuntimeTurnConfiguration = AgentRuntimeTurnConfiguration(),
        harness: AgentHarnessConfiguration = AgentHarnessConfiguration.default
    ) -> AgentRuntimeTurnConfiguration {
        submission.runtimeTurnConfiguration(base: base, harness: harness)
    }
}
