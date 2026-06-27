import Foundation

public enum ControlInputBoundaryOutcome: Sendable {
    /// Control input fully handled; the model must not run.
    case shortCircuit(ChatStreamResponse)
    /// Continue the model turn with stripped prose and optional turn-scoped overrides.
    case continueTurn(
        modelText: String,
        configurationPatch: ControlInputTurnConfigurationPatch,
        preTurnAckContent: String?
    )
    /// No control-input handling required.
    case passthrough
}

extension SlashCommandDispatchService {
    func processControlInputBoundary(
        text: String,
        conversationID: UUID,
        trustClass: TrustPolicyClass?,
        senderLabel: String? = nil,
        capabilities: ControlSurfaceCapabilities = .terminal
    ) async throws -> ControlInputBoundaryOutcome {
        let runtimeConfig = slashCommandRuntimeConfiguration
        guard runtimeConfig.enabled else { return .passthrough }

        let registry = await buildSlashCommandRegistry(conversationID: conversationID)
        let authorization = await makeControlInputAuthorization(
            conversationID: conversationID,
            trustClass: trustClass
        )
        let classifier = ControlInputClassifier(
            registry: registry,
            capabilities: capabilities,
            configuration: ControlInputClassifierConfiguration(
                slashCommandsEnabled: runtimeConfig.enabled,
                directivesEnabled: runtimeConfig.directivesEnabled,
                inlineShortcutsEnabled: runtimeConfig.inlineShortcutsEnabled,
                allowUnknownPassthrough: runtimeConfig.allowUnknownPassthrough
            )
        )

        switch classifier.classify(input: text, authorization: authorization) {
        case .plainText:
            return .passthrough
        case let .command(command, parsed):
            if let response = try await runSlashCommandIfNeeded(
                text,
                conversationID: conversationID,
                skipQueue: false,
                isOwner: authorization.isOwner
            ) {
                return .shortCircuit(response)
            }
            if let content = renderCatalogShortcut(
                command: command,
                parsed: parsed,
                registry: registry,
                senderLabel: senderLabel
            ) {
                let response = try await deliverSyntheticSlashAssistantResponse(
                    conversationID: conversationID,
                    content: content,
                    preserveGeneratingState: false
                )
                return .shortCircuit(response)
            }
            return .passthrough
        case let .directiveOnly(directives):
            try await persistDirectives(directives, conversationID: conversationID, authorization: authorization)
            let ack = DirectiveCatalog.acknowledgement(for: directives)
            let response = try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: ack,
                preserveGeneratingState: false
            )
            return .shortCircuit(response)
        case let .inlineHint(directives, prose):
            let patch = classifier.turnConfigurationPatch(from: directives)
            return .continueTurn(
                modelText: prose,
                configurationPatch: patch,
                preTurnAckContent: nil
            )
        case let .inlineShortcut(shortcuts, remainingProse):
            let content = shortcuts.map {
                InlineShortcutCatalog.render($0, registry: registry, senderLabel: senderLabel)
            }.joined(separator: "\n")
            return .continueTurn(
                modelText: remainingProse,
                configurationPatch: ControlInputTurnConfigurationPatch(),
                preTurnAckContent: content
            )
        }
    }

    func makeControlInputAuthorization(
        conversationID: UUID,
        trustClass: TrustPolicyClass?
    ) async -> ControlInputAuthorization {
        let conversation = await deps.persistenceDomain.modelConversation(id: conversationID)
        let authenticatedOwner = APISessionContext.authenticatedOwnerAccountID
        let isOwner: Bool = {
            guard let ownerAccountID = conversation?.ownerAccountID else { return true }
            guard let authenticatedOwner else { return true }
            return ownerAccountID == authenticatedOwner
        }()
        return ControlInputAuthorization(
            isOwner: isOwner,
            trustClass: trustClass ?? .trusted,
            allowlistAllows: isOwner
        )
    }

    private func persistDirectives(
        _ directives: [AppliedDirective],
        conversationID: UUID,
        authorization: ControlInputAuthorization
    ) async throws {
        for directive in directives {
            switch directive.kind {
            case .think, .reasoning:
                if let config = directive.thinkingConfig {
                    try await deps.persistenceDomain.updateConversationThinkingConfig(
                        conversationID: conversationID,
                        thinkingConfig: config
                    )
                }
            case .model:
                guard authorization.isOwner else { continue }
                if let slug = directive.modelSlug {
                    try await persistModelDirective(slug: slug, conversationID: conversationID)
                }
            case .verbose, .elevated, .queue:
                break
            }
        }
    }

    private func persistModelDirective(slug: String, conversationID: UUID) async throws {
        guard let reference = ModelReference.parse(slug) else { return }
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else { return }
        guard let rankedRegistryEntriesProvider = deps.rankedRegistryEntriesProvider else { return }
        let entries = await rankedRegistryEntriesProvider(reference)
        guard let entry = entries.first else { return }
        _ = try await deps.persistenceDomain.updateConversationModelAndUserPrompt(
            conversationID: conversationID,
            model: entry.toModel(),
            userSystemPrompt: conversation.systemPrompt
        )
    }

    private func renderCatalogShortcut(
        command: SlashCommand,
        parsed: ParsedSlashCommand,
        registry: SlashCommandRegistry,
        senderLabel: String?
    ) -> String? {
        if let kind = InlineShortcutCatalog.kind(for: parsed.name) {
            return InlineShortcutCatalog.render(
                InlineShortcutInvocation(kind: kind),
                registry: registry,
                senderLabel: senderLabel
            )
        }
        guard command.base.category == .inlineShortcut else { return nil }
        return command.base.description
    }
}
