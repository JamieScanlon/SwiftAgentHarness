import Foundation
import SwiftAgentKit
import Vapor

enum HarnessEmbeddedMutation {
    static func embeddedAPISession(defaultSession: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession()) -> EmbeddedHarnessAPISession {
        var session = defaultSession
        if session.connectionNamespace == nil,
           let namespace = APISessionContext.connectionNamespace {
            session.connectionNamespace = namespace
        }
        return session
    }

    static func currentTransport() async -> (any HarnessMutationTransporting)? {
        await HarnessMutationTransportHolder.shared.currentTransport()
    }

    static func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?,
        originSenderIsOwner: Bool? = nil,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallbackRuntime: (any APILayerChatRuntimeManaging)? = nil
    ) async throws {
        // Only a *negative* verdict crosses the transport. The loopback client serializes this into
        // a `ChatRequest` body, which is indistinguishable from any other caller's body at the REST
        // boundary, so an affirmative claim would be forgeable. `false` becomes a self-restriction
        // the receiver can safely honor; `true`/`nil` assert nothing and let the REST side resolve
        // ownership from the authenticated principal instead.
        let senderIsNonOwner: Bool? = originSenderIsOwner == false ? true : nil
        let resolvedSession = embeddedAPISession(defaultSession: session)
        if let transport = await currentTransport() {
            var messageText = text
            if let systemReminder, !systemReminder.isEmpty {
                messageText = systemReminder + "\n\n" + messageText
            }
            var ifMatch: String?
        if let client = transport as? EmbeddedHarnessAPIClient {
            ifMatch = try? await EmbeddedHarnessAPIPreconditionSupport.messageTailIfMatch(
                client: client,
                session: resolvedSession,
                conversationID: conversationID
            )
        }
        _ = try await transport.sendMessage(
            session: resolvedSession,
            conversationID: conversationID,
            request: EmbeddedSendMessageRequest(
                message: messageText,
                includeTools: enableTools,
                includeAgents: enableAgents,
                inputTrust: inputTrustRaw,
                ifMatch: ifMatch,
                originSurface: originSurface,
                originSenderID: originSenderID,
                originSenderIsNonOwner: senderIsNonOwner
            )
        )
            return
        }
        guard let fallbackRuntime else {
            throw HarnessMutationTransportError.notConfigured
        }
        _ = try await fallbackRuntime.apiSendMessageAndStreamResponse(
            conversationID: conversationID,
            text,
            images: [],
            enableTools: enableTools,
            enableAgents: enableAgents,
            expectedPreviousTailHarnessMessageID: nil,
            inputTrustRaw: inputTrustRaw,
            resolvedInputTrustClass: resolvedInputTrustClass,
            systemReminder: systemReminder,
            originSurface: originSurface,
            originSenderID: originSenderID,
            // In-process: nothing is serialized, so the verdict travels intact rather than being
            // narrowed to a self-restriction.
            originSenderIsOwner: originSenderIsOwner
        )
    }

    static func sendMessageAndDrain(
        conversationID: UUID,
        prompt: String,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallback: @escaping @Sendable () async throws -> Void
    ) async throws {
        let resolvedSession = embeddedAPISession(defaultSession: session)
        guard let transport = await currentTransport() else {
            try await fallback()
            return
        }
        var ifMatch: String?
        if let client = transport as? EmbeddedHarnessAPIClient {
            ifMatch = try await EmbeddedHarnessAPIPreconditionSupport.messageTailIfMatch(
                client: client,
                session: resolvedSession,
                conversationID: conversationID
            )
        }
        _ = try await transport.sendMessage(
            session: resolvedSession,
            conversationID: conversationID,
            request: EmbeddedSendMessageRequest(
                message: prompt,
                ifMatch: ifMatch
            )
        )
    }

    static func cancelChildRun(
        conversationID: UUID,
        runID: UUID,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallback: @escaping @Sendable () async throws -> Void
    ) async throws {
        let resolvedSession = embeddedAPISession(defaultSession: session)
        guard let transport = await currentTransport() else {
            try await fallback()
            return
        }
        try await transport.cancelRun(
            session: resolvedSession,
            conversationID: conversationID,
            runID: runID,
            ifMatch: nil
        )
    }

    static func createConversation(
        modelRef: String,
        topic: String?,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallback: @escaping @Sendable (String?) async throws -> UUID
    ) async throws -> UUID {
        let resolvedSession = embeddedAPISession(defaultSession: session)
        guard let transport = await currentTransport() else {
            return try await fallback(topic)
        }
        return try await transport.createConversation(
            session: resolvedSession,
            request: EmbeddedCreateConversationRequest(
                modelRef: modelRef,
                topic: topic
            )
        )
    }

    static func persistDirectives(
        directives: [AppliedDirective],
        conversationID: UUID,
        authorization: ControlInputAuthorization,
        currentConversation: ModelConversation,
        rankedRegistryEntriesProvider: (@Sendable (ModelReference) async -> [ModelRegistryEntry])?,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession()
    ) async throws -> Bool {
        guard !APISessionContext.servingRESTRequest else { return false }
        guard let transport = await currentTransport() else { return false }
        let resolvedSession = embeddedAPISession(defaultSession: session)
        var metadata = currentConversation.metadata
        var routingModelOptions = currentConversation.routingPrefs?.modelOptions
        var modelRef: String?
        var metadataChanged = false
        var routingChanged = false
        for directive in directives {
            switch directive.kind {
            case .think, .reasoning:
                if let config = directive.thinkingConfig {
                    var options = routingModelOptions ?? ConversationRoutingModelOptions()
                    options.thinkingConfig = config
                    routingModelOptions = options
                    routingChanged = true
                }
            case .model:
                guard authorization.isOwner else { continue }
                if let slug = directive.modelSlug {
                    modelRef = slug
                }
            case .verbose:
                metadata = ActiveMemorySessionFlags.withVerbose(
                    directive.onOffFlag ?? true,
                    metadata: metadata
                )
                metadataChanged = true
            case .trace:
                metadata = ActiveMemorySessionFlags.withTrace(
                    directive.onOffFlag ?? true,
                    metadata: metadata
                )
                metadataChanged = true
            case .elevated, .queue:
                break
            }
        }
        guard metadataChanged || routingChanged || modelRef != nil else { return true }
        var ifMatch: String?
        var expectedRevision = currentConversation.controlPlaneRevision
        if let client = transport as? EmbeddedHarnessAPIClient {
            ifMatch = try await EmbeddedHarnessAPIPreconditionSupport.conversationControlPlaneIfMatch(
                client: client,
                session: resolvedSession,
                conversationID: conversationID
            )
            if let revision = try await EmbeddedHarnessAPIPreconditionSupport.conversationControlPlaneRevision(
                client: client,
                session: resolvedSession,
                conversationID: conversationID
            ) {
                expectedRevision = revision
            }
        }
        var patch = ConversationPatch(expectedRevision: expectedRevision)
        if metadataChanged {
            patch.metadata = metadata
        }
        if routingChanged, let routingModelOptions {
            patch.routingModelOptions = routingModelOptions
        }
        if let modelRef,
           let reference = ModelReference.parse(modelRef),
           let rankedRegistryEntriesProvider {
            let entries = await rankedRegistryEntriesProvider(reference)
            if entries.first != nil {
                patch.modelRef = modelRef
                patch.userSystemPrompt = currentConversation.systemPrompt
            }
        }
        try await transport.patchConversation(
            session: resolvedSession,
            conversationID: conversationID,
            patch: patch,
            ifMatch: ifMatch
        )
        return true
    }

    static func resolveExecApproval(
        approvalID: String,
        approved: Bool,
        durable: Bool,
        reason: String?,
        session: EmbeddedHarnessAPISession = EmbeddedHarnessAPISession(),
        fallback: @escaping @Sendable () async -> ExecApprovalResolution?
    ) async -> ExecApprovalResolution? {
        let resolvedSession = embeddedAPISession(defaultSession: session)
        guard let transport = await currentTransport() else {
            return await fallback()
        }
        do {
            try await transport.resolveExecApproval(
                session: resolvedSession,
                approvalID: approvalID,
                approved: approved,
                durable: durable,
                reason: reason
            )
            return approved ? .approved(durable: durable) : .denied(reason ?? "denied")
        } catch HarnessMutationTransportError.unexpectedStatus(.notFound) {
            return nil
        } catch {
            return await fallback()
        }
    }
}
