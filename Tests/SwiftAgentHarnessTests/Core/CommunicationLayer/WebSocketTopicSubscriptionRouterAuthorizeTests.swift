import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor RouterAuthLineCollector {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

private final class SubscribeRouterConversationDouble: APILayerConversationManaging, Sendable {
    private let conversationsByID: [UUID: ModelConversation]
    private let registryScope: UUID?

    init(conversationsByID: [UUID: ModelConversation], registryScope: UUID?) {
        self.conversationsByID = conversationsByID
        self.registryScope = registryScope
    }

    func apiGetConversation(id: UUID) async -> ModelConversation? { conversationsByID[id] }
    func apiRegistryOwnerAccountID() async -> UUID? { registryScope }

    func apiListConversationInfo() async -> [ModelConversation] { [] }
    func apiListConversationMetadata(visibility: ConversationCatalogVisibilityFilter) async -> [ConversationMetadata] { [] }
    func apiListCurrentMessages() async -> [Message] { [] }
    func apiListCurrentMessagesThrowing() async throws -> [Message] { [] }
    func apiGenerateFullSystemPrompt(withUserSystemPrompt userSystemPrompt: String?) async throws -> String { "" }
    func apiSelectConversation(conversationID: UUID) async throws { _ = conversationID }
    func apiCreateConversation(
        with selectedModel: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode
    ) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode?
    ) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationModelAndUserPrompt(conversationID: UUID, model: Model?, userSystemPrompt: String?) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiListAvailableTools() async throws -> [AvailableToolInfo] { [] }
    func apiListAvailableSkills() async throws -> [AvailableSkillInfo] { [] }
    func apiListSlashCommands() async throws -> [SlashCommandAutocompleteEntry] { [] }
    func apiUpdateConversationToolOverrides(conversationID: UUID, routingPolicyTools: [String]) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationSkillOverrides(conversationID: UUID, routingPolicySkills: [String]) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiUpdateConversationThinkingConfig(conversationID: UUID, thinkingConfig: ThinkingConfig?) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiCopyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiDeleteConversation(conversationID: UUID, hard: Bool) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiSnapshotOrchestrationState(conversationID: UUID) async -> ConversationOrchestrationState? {
        _ = conversationID
        return nil
    }

    func apiReadPlanMarkdown(conversationID: UUID) async throws -> String {
        throw APILayerConversationAPIError.unsupported
    }

    func apiLatestTranscriptSequence(conversationID: UUID) async -> Int? {
        _ = conversationID
        return 0
    }

    func apiReadTranscriptEntries(conversationID: UUID, request: SessionTranscriptReadRequest) async throws -> [SessionTranscriptEntry] {
        _ = conversationID
        _ = request
        return []
    }

    var currentConversationID: UUID? { nil }
}

struct WebSocketTopicSubscriptionRouterAuthorizeTests {
    private func fixtureModel(id: UUID) -> Model {
        WebSocketRouterTestFixtures.model(id: id)
    }

    private func fixtureConversation(id: UUID, owner: UUID?, modelID: UUID) -> ModelConversation {
        ModelConversation(id: id, model: fixtureModel(id: modelID), ownerAccountID: owner)
    }

    @Test func subscribeConversationEventsDeniedWhenConversationMissing() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.conversationEventsTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let session = SubscribeRouterConversationDouble(conversationsByID: [:], registryScope: nil)

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: hub,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: session,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: ConversationTopicFormat.topic(conversationID: cid),
                since: nil
            ),
            registration: registration
        )

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        let lines = await collector.lines
        #expect(lines.isEmpty)
    }

    @Test func subscribeConversationEventsDeniedWhenTenancyMismatch() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let scope = UUID()
        let wrongOwner = UUID()
        let conv = fixtureConversation(id: cid, owner: wrongOwner, modelID: UUID())
        let session = SubscribeRouterConversationDouble(conversationsByID: [cid: conv], registryScope: scope)
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.conversationEventsTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: hub,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: session,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: ConversationTopicFormat.topic(conversationID: cid),
                since: nil
            ),
            registration: registration
        )

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }

    @Test func subscribeConversationEventsAllowedWhenConversationVisible() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let mid = UUID()
        let conv = fixtureConversation(id: cid, owner: nil, modelID: mid)
        let session = SubscribeRouterConversationDouble(conversationsByID: [cid: conv], registryScope: nil)
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.conversationEventsTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: hub,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: session,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: ConversationTopicFormat.topic(conversationID: cid),
                since: nil
            ),
            registration: registration
        )

        #expect(err == nil)
        let lines = await collector.lines
        #expect(!lines.isEmpty)
    }

    @Test func subscribeTraceConversationDeniedWhenConversationMissing() async throws {
        let hub = TraceTopicHub()
        let cid = UUID()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.traceTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let session = SubscribeRouterConversationDouble(conversationsByID: [:], registryScope: nil)

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: hub,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: session,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: TraceTopicFormat.conversationTopic(conversationID: cid),
                since: nil
            ),
            registration: registration
        )

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }

    @Test func subscribeTraceServerAllowedWhenOperatorEnforcementDisabled() async throws {
        let hub = TraceTopicHub()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.traceTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let session = SubscribeRouterConversationDouble(conversationsByID: [:], registryScope: nil)

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: hub,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: session,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: TraceTopicFormat.serverTopic, since: nil),
            registration: registration
        )

        #expect(err == nil)
        #expect(await collector.lines.count == 1)
    }

    @Test func subscribeTraceServerDeniedWhenOperatorEnforcementActiveWithoutOwner() async throws {
        let hub = TraceTopicHub()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.traceTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let session = SubscribeRouterConversationDouble(conversationsByID: [:], registryScope: nil)
        let policy = ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [UUID()])

        let err = await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                modelHub: nil,
                conversationHub: nil,
                conversationStateHub: nil,
                traceHub: hub,
                subAgentLifecycleHub: nil,
                capabilityRegistryHub: nil,
                conversationsRegistryHub: nil,
                coordinator: nil,
                conversationSession: session,
                chatRuntime: nil,
                modelManager: nil,
                serverTraceSubscribePolicy: policy,
                message: CommClientControlMessage(kind: .subscribe, topic: TraceTopicFormat.serverTopic, since: nil),
                registration: registration
            )
        }

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }

    @Test func subscribeTraceServerAllowedForAllowlistedOperator() async throws {
        let hub = TraceTopicHub()
        let operatorID = UUID()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.traceTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let session = SubscribeRouterConversationDouble(conversationsByID: [:], registryScope: nil)
        let policy = ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [operatorID])

        let err = await APISessionContext.$authenticatedOwnerAccountID.withValue(operatorID) {
            await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                modelHub: nil,
                conversationHub: nil,
                conversationStateHub: nil,
                traceHub: hub,
                subAgentLifecycleHub: nil,
                capabilityRegistryHub: nil,
                conversationsRegistryHub: nil,
                coordinator: nil,
                conversationSession: session,
                chatRuntime: nil,
                modelManager: nil,
                serverTraceSubscribePolicy: policy,
                message: CommClientControlMessage(kind: .subscribe, topic: TraceTopicFormat.serverTopic, since: nil),
                registration: registration
            )
        }

        #expect(err == nil)
        #expect(await collector.lines.count == 1)
    }

    @Test func subscribePoolHealthDeniedWhenOperatorEnforcementActiveWithoutOwner() async throws {
        let hub = ModelStateTopicHub()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let policy = ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [UUID()])

        let err = await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                modelHub: hub,
                conversationHub: nil,
                conversationStateHub: nil,
                traceHub: nil,
                subAgentLifecycleHub: nil,
                capabilityRegistryHub: nil,
                conversationsRegistryHub: nil,
                coordinator: nil,
                conversationSession: nil,
                chatRuntime: nil,
                modelManager: nil,
                serverTraceSubscribePolicy: policy,
                message: CommClientControlMessage(kind: .subscribe, topic: ResourceTopicName.poolHealth, since: nil),
                registration: registration
            )
        }

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }

    @Test func subscribeModelStateDeniedWhenModelNotInCatalog() async throws {
        let hub = ModelStateTopicHub()
        let coordinator = ModelInvocationCoordinator()
        let unknownModel = UUID()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let catalog = SubscribeRouterModelManagerDouble(models: [])

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: coordinator,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: catalog,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: ModelStateTopicFormat.topic(modelID: unknownModel),
                since: nil
            ),
            registration: registration
        )

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }

    @Test func subscribeModelStateAllowedWhenModelInCatalog() async throws {
        let hub = ModelStateTopicHub()
        let coordinator = ModelInvocationCoordinator()
        let mid = UUID()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let catalog = SubscribeRouterModelManagerDouble(models: [fixtureModel(id: mid)])

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: coordinator,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: catalog,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: ModelStateTopicFormat.topic(modelID: mid),
                since: nil
            ),
            registration: registration
        )

        #expect(err == nil)
        let lines = await collector.lines
        #expect(lines.count >= 1)
    }

    @Test func dualReplayControlFieldsRejectedForNonConversationTopic() async throws {
        let hub = ModelStateTopicHub()
        let registration = WebSocketTopicWireRegistration()
        registration.modelTopicHubToken = await hub.registerConnection { line in
            _ = line
        }

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: hub,
            conversationHub: nil,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: nil,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(kind: .subscribe, topic: ResourceTopicName.poolHealth, sinceMessageSeq: 0),
            registration: registration
        )

        #expect(err?.contains("only valid for conversation") == true)
    }

    @Test func sinceCannotCombineWithSinceMessageSeqOnConversationEvents() async throws {
        let convHub = ConversationEventsTopicHub()
        let cid = UUID()
        let modelID = UUID()
        let conv = fixtureConversation(id: cid, owner: nil, modelID: modelID)
        let session = SubscribeRouterConversationDouble(conversationsByID: [cid: conv], registryScope: nil)
        let registration = WebSocketTopicWireRegistration()
        registration.conversationEventsTopicHubToken = await convHub.registerConnection { _ in }

        let err = await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
            modelHub: nil,
            conversationHub: convHub,
            conversationStateHub: nil,
            traceHub: nil,
            subAgentLifecycleHub: nil,
            capabilityRegistryHub: nil,
            conversationsRegistryHub: nil,
            coordinator: nil,
            conversationSession: session,
            chatRuntime: nil,
            modelManager: nil,
            message: CommClientControlMessage(
                kind: .subscribe,
                topic: ConversationTopicFormat.topic(conversationID: cid),
                since: 0,
                sinceMessageSeq: 0
            ),
            registration: registration
        )

        #expect(err?.contains("since cannot be combined") == true)
    }

    @Test func subscribeConversationEventsDeniedWhenStrictTenancyWithoutOwner() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let mid = UUID()
        let conv = fixtureConversation(id: cid, owner: UUID(), modelID: mid)
        let session = SubscribeRouterConversationDouble(conversationsByID: [cid: conv], registryScope: nil)
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.conversationEventsTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let strictTenancy = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)

        let err = await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                modelHub: nil,
                conversationHub: hub,
                conversationStateHub: nil,
                traceHub: nil,
                subAgentLifecycleHub: nil,
                capabilityRegistryHub: nil,
                conversationsRegistryHub: nil,
                coordinator: nil,
                conversationSession: session,
                chatRuntime: nil,
                modelManager: nil,
                tenancyPolicy: strictTenancy,
                message: CommClientControlMessage(
                    kind: .subscribe,
                    topic: ConversationTopicFormat.topic(conversationID: cid),
                    since: nil
                ),
                registration: registration
            )
        }

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }

    @Test func subscribeConversationEventsAllowedWhenStrictTenancyOwnerMatches() async throws {
        let hub = ConversationEventsTopicHub()
        let cid = UUID()
        let mid = UUID()
        let owner = UUID()
        let conv = fixtureConversation(id: cid, owner: owner, modelID: mid)
        let session = SubscribeRouterConversationDouble(conversationsByID: [cid: conv], registryScope: nil)
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.conversationEventsTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let strictTenancy = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)

        let err = await APISessionContext.$authenticatedOwnerAccountID.withValue(owner) {
            await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                modelHub: nil,
                conversationHub: hub,
                conversationStateHub: nil,
                traceHub: nil,
                subAgentLifecycleHub: nil,
                capabilityRegistryHub: nil,
                conversationsRegistryHub: nil,
                coordinator: nil,
                conversationSession: session,
                chatRuntime: nil,
                modelManager: nil,
                tenancyPolicy: strictTenancy,
                message: CommClientControlMessage(
                    kind: .subscribe,
                    topic: ConversationTopicFormat.topic(conversationID: cid),
                    since: nil
                ),
                registration: registration
            )
        }

        #expect(err == nil)
        let lines = await collector.lines
        #expect(!lines.isEmpty)
    }

    @Test func subscribeConversationsRegistryDeniedWhenStrictTenancyWithoutOwner() async throws {
        let hub = ConversationsRegistryTopicHub()
        let collector = RouterAuthLineCollector()
        let registration = WebSocketTopicWireRegistration()
        registration.conversationsRegistryTopicHubToken = await hub.registerConnection { line in
            await collector.append(line.json)
        }
        let session = SubscribeRouterConversationDouble(conversationsByID: [:], registryScope: nil)
        let strictTenancy = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)

        let err = await APISessionContext.$authenticatedOwnerAccountID.withValue(nil) {
            await WebSocketTopicSubscriptionRouter.applyCommClientControlMessage(
                modelHub: nil,
                conversationHub: nil,
                conversationStateHub: nil,
                traceHub: nil,
                subAgentLifecycleHub: nil,
                capabilityRegistryHub: nil,
                conversationsRegistryHub: hub,
                coordinator: nil,
                conversationSession: session,
                chatRuntime: nil,
                modelManager: nil,
                tenancyPolicy: strictTenancy,
                message: CommClientControlMessage(
                    kind: .subscribe,
                    topic: ResourceTopicName.conversationsRegistry,
                    since: nil
                ),
                registration: registration
            )
        }

        #expect(err == WebSocketTopicSubscribeAuthorization.deniedMessage)
        #expect(await collector.lines.isEmpty)
    }
}
