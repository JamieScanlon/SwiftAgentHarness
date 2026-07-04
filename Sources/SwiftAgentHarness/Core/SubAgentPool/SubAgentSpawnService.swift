import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator

/// Sub-agent spawn, lifecycle tracking, and runtime coordination (Slice 4 migration).
public actor SubAgentSpawnService {
    private let deps: ConversationRuntimeDependencies
    private let orchestratorRuntime: any SubAgentOrchestratorRuntimeServicing
    private let agentRuntime: any AgentRuntimeOrchestratorBinding & AgentRuntimeRunControlling & AgentRuntimeLaneErrorMapping
    private let topics: ConversationTopicPublicationPort
    private let messaging: ConversationMessagingPort
    private let orchestrator: OrchestratorSessionPort
    private let startup: ConversationStartupService
    private let lifecycle: any ConversationLifecycleServicing
    private let completionService: SubAgentCompletionRuntimeService

    nonisolated let subAgentPool: any SubAgentPooling
    private var subAgentLifecycleState = SubAgentLifecycleState()
    private let subAgentDelegateEventTranslator = SubAgentDelegateEventTranslator()
    private lazy var subAgentRunScheduler: any SubAgentRunScheduling = RuntimeLaneSubAgentRunScheduler(
        runtimeLaneCoordinator: deps.runtimeLaneCoordinator
    )
    private lazy var subAgentInvocationLifecycleCoordinator: any SubAgentInvocationLifecycleTracking = SubAgentInvocationCoordinator(
        scheduler: subAgentRunScheduler
    )

    init(
        deps: ConversationRuntimeDependencies,
        subAgentPool: any SubAgentPooling,
        completionService: SubAgentCompletionRuntimeService,
        orchestratorRuntime: any SubAgentOrchestratorRuntimeServicing,
        agentRuntime: any AgentRuntimeOrchestratorBinding & AgentRuntimeRunControlling & AgentRuntimeLaneErrorMapping,
        topics: ConversationTopicPublicationPort,
        messaging: ConversationMessagingPort,
        orchestrator: OrchestratorSessionPort,
        startup: ConversationStartupService,
        lifecycle: any ConversationLifecycleServicing
    ) {
        self.deps = deps
        self.subAgentPool = subAgentPool
        self.completionService = completionService
        self.orchestratorRuntime = orchestratorRuntime
        self.agentRuntime = agentRuntime
        self.topics = topics
        self.messaging = messaging
        self.orchestrator = orchestrator
        self.startup = startup
        self.lifecycle = lifecycle
    }

    func conversationTopicPublisherConfigured() async -> Bool {
        await startup.conversationTopicPublisherForRuntime() != nil
    }

    func subAgentLifecyclePublisherConfigured() async -> Bool {
        await startup.subAgentLifecyclePublisherForRuntime() != nil
    }

    func installACPPermissionCoordinator(toolApproval: ToolApprovalRuntimeService) async {
        await SubAgentACPPermissionCoordinator.shared.configure(
            emitEvent: { [weak self] event in
                await self?.applySubAgentDelegateEvent(event)
            },
            registerPendingApproval: { conversationID, runID, toolName, route, _, _ in
                _ = await toolApproval.registerPendingToolApproval(
                    conversationID: conversationID,
                    runID: runID,
                    toolName: toolName,
                    route: route,
                    isElevated: false
                )
            }
        )
    }

    private var subAgentExecutionCoordinator: SubAgentExecutionCoordinator {
        SubAgentExecutionCoordinator(subAgentPool: subAgentPool)
    }

    public func spawnSubAgentViaPool(
        parentConversationID: UUID,
        request: SubAgentSpawnRequest,
        modelOverride: Model?,
        bypassDelegateAllowList: Bool = false
    ) async throws -> UUID {
        guard let parentConversation = await deps.persistenceDomain.modelConversation(id: parentConversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        await orchestratorRuntime.setupOrchestrator(with: parentConversation.model, activeConversation: parentConversation)
        let orchestrationEntries = await subAgentPool.refreshSubAgentCatalog(conversationID: parentConversationID) { [orchestratorRuntime, agentRuntime] _ in
            guard let orchestrator = await agentRuntime.orchestrator(for: parentConversationID) else { return [] }
            return await orchestratorRuntime.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
        }
        let parentProfile = await resolvedModeProfile(for: parentConversation)
        let parentDepth = await conversationDepth(conversationID: parentConversationID)
        let preparedLaunch = try await subAgentExecutionCoordinator.prepareLaunch(
            parentConversationID: parentConversationID,
            parentConversation: parentConversation,
            request: request,
            orchestrationEntries: orchestrationEntries,
            modeSubAgentAllowList: bypassDelegateAllowList ? ["*"] : parentProfile.subAgents.allow,
            modeProfileMaxDepth: parentProfile.subAgents.maxDepth,
            parentDepth: parentDepth
        )
        let launchPlan = preparedLaunch.launchPlan
        let lifecycleID = launchPlan.asyncHandleID
            ?? "spawn-\(parentConversationID.uuidString)-\(UUID().uuidString)"
        let rootConversationID = await subAgentRootConversationID(for: parentConversationID)
        let lifecyclePathSegments = await assignSubAgentPathSegments(
            lifecycleID: lifecycleID,
            rootConversationID: rootConversationID,
            parentConversationID: parentConversationID
        )
        let parentRoute: ToolApprovalRoute = switch launchPlan.delegationContext.effectivePermissionPolicy {
        case .askParent: .parent
        case .askUser, .auto: .user
        }
        let initialLifecycle = SubAgentLifecycleEntryPayload(
            lifecycleID: lifecycleID,
            parentConversationID: parentConversationID,
            childConversationID: nil,
            delegateToolName: launchPlan.delegationContext.delegateToolName,
            asyncHandleID: launchPlan.asyncHandleID,
            phase: .queued,
            defaultTrustLevel: launchPlan.delegationContext.effectiveTrustLevel.rawValue,
            permissionPolicy: launchPlan.delegationContext.effectivePermissionPolicy.rawValue,
            approvalRoute: parentRoute
        )
        let selectedToolEntry = preparedLaunch.selectedToolEntry
        subAgentLifecycleState.setTransportContext(
            lifecycleID: lifecycleID,
            context: .init(
                transportKind: launchPlan.delegationContext.transportKind,
                sessionHandleID: launchPlan.delegationContext.resolvedAgentID ?? launchPlan.delegationContext.delegateToolName ?? lifecycleID,
                completionHandleID: launchPlan.asyncHandleID
            )
        )
        await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: initialLifecycle)
        await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
        var remoteCorrelation: SubAgentTransportInvocationCorrelation?
        var adapterDelegateEvents: [SubAgentDelegateEvent] = []
        if let selectedRegistryEntry = preparedLaunch.selectedRegistryEntry,
           let selectedToolEntry {
            let transportResult = try await subAgentPool.invokeSubAgent(
                launchPlan: launchPlan,
                registryEntry: selectedRegistryEntry,
                toolEntry: selectedToolEntry,
                parentConversationID: parentConversationID
            )
            adapterDelegateEvents = transportResult.delegateEvents
            if case let .remoteStarted(correlation) = transportResult.outcome {
                remoteCorrelation = correlation
                subAgentLifecycleState.setTransportContext(
                    lifecycleID: lifecycleID,
                    context: .init(
                        transportKind: correlation.transportKind,
                        sessionHandleID: correlation.sessionHandleID,
                        completionHandleID: correlation.completionHandleID
                    )
                )
                await completionService.registerHandleOwnership(
                    conversationID: parentConversationID,
                    sessionHandleID: correlation.sessionHandleID,
                    completionHandleID: correlation.completionHandleID
                )
                deps.logger?.debug("[SubAgentSpawnService] sub-agent transport started remotely: session=\(correlation.sessionHandleID), handle=\(correlation.completionHandleID ?? "none")")
            }
        }
        let parentRunID = await deps.persistenceDomain.modelConversation(id: parentConversationID)?.currentRunID
        let reservation = SubAgentRunReservation(
            parentConversationID: parentConversationID,
            parentRunID: parentRunID,
            lifecycleID: lifecycleID,
            priority: .foreground
        )
        do {
            _ = try await subAgentInvocationLifecycleCoordinator.beginInvocation(
                reservation: reservation
            )
        } catch let admission as RuntimeLaneAdmissionError {
            var rejected = initialLifecycle
            rejected.phase = SubAgentLifecyclePhase.failed
            rejected.error = "lane_admission_failed"
            rejected.updatedAt = Date()
            await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: rejected)
            await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            throw await agentRuntime.runtimeSessionError(
                for: admission,
                conversationID: parentConversationID,
                fallbackRunID: UUID()
            )
        } catch {
            var rejected = initialLifecycle
            rejected.phase = SubAgentLifecyclePhase.failed
            rejected.error = "lane_admission_failed"
            rejected.updatedAt = Date()
            await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: rejected)
            await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            throw SubAgentPoolError.admissionRejected(reason: "\(error)")
        }
        var admitted = initialLifecycle
        admitted.phase = SubAgentLifecyclePhase.dispatching
        admitted.updatedAt = Date()
        await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: admitted)
        await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
        var runLaneHandoffCommitted = false
        defer {
            if !runLaneHandoffCommitted {
                Task { [subAgentInvocationLifecycleCoordinator] in
                    await subAgentInvocationLifecycleCoordinator.endInvocation(lifecycleID: lifecycleID)
                }
            }
        }
        if let remoteCorrelation {
            if let completionHandleID = remoteCorrelation.completionHandleID {
                await subAgentPool.completionHandoffOwner.registerBackgroundLaunch(
                    handleID: completionHandleID,
                    conversationID: parentConversationID,
                    parentConversationID: parentConversationID
                )
            }
            if adapterDelegateEvents.isEmpty {
                var remoteRunning = admitted
                remoteRunning.phase = SubAgentLifecyclePhase.completing
                remoteRunning.asyncHandleID = remoteCorrelation.completionHandleID ?? remoteRunning.asyncHandleID
                remoteRunning.updatedAt = Date()
                await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: remoteRunning)
                await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            } else {
                for event in adapterDelegateEvents {
                    await applySubAgentDelegateEvent(event)
                }
            }
            let stream = await subAgentPool.streamDelegateEvents(
                SubAgentTransportDelegateEventsRequest(
                    correlation: remoteCorrelation,
                    parentConversationID: parentConversationID
                )
            )
            Task { [weak self] in
                guard let self else { return }
                for await event in stream {
                    await self.applySubAgentDelegateEvent(event)
                }
            }
            runLaneHandoffCommitted = true
            return parentConversationID
        }

        switch launchPlan.spawnPlan {
        case .fork(let userMessageID):
            let selectionBehavior: BranchSelectionBehavior = launchPlan.request.runInBackground
                ? .preserveForeground
                : .adoptChild
            let childID = try await lifecycle.branchConversation(
                conversationID: parentConversationID,
                userMessageID: userMessageID,
                selectionBehavior: selectionBehavior,
                childLineageKind: .subAgent
            )
            let meta = metadataBySettingSubAgentDepth(
                launchPlan.request.metadata ?? parentConversation.metadata,
                depth: parentDepth + 1,
                lifecycleID: lifecycleID,
                delegateToolName: launchPlan.delegationContext.delegateToolName,
                asyncHandleID: launchPlan.asyncHandleID,
                rootConversationID: rootConversationID,
                pathSegments: lifecyclePathSegments,
                transportKind: launchPlan.delegationContext.transportKind,
                sessionHandleID: launchPlan.delegationContext.resolvedAgentID ?? launchPlan.delegationContext.delegateToolName ?? lifecycleID,
                completionHandleID: launchPlan.asyncHandleID,
                routingContext: launchPlan.request.routingContext
            )
            try await applyChildRoleCapabilities(
                childID: childID,
                launchPlan: launchPlan,
                parentProfile: parentProfile,
                metadata: meta
            )
            await linkDelegateCost(childConversationID: childID, parentConversationID: parentConversationID)
            var running = admitted
            running.phase = SubAgentLifecyclePhase.running
            running.childConversationID = childID
            running.updatedAt = Date()
            await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: running)
            await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            runLaneHandoffCommitted = true
            return childID
        case .isolated:
            guard let parent = await deps.persistenceDomain.modelConversation(id: parentConversationID) else {
                throw ConversationServiceError.conversationNotFound
            }
            let model = modelOverride ?? parent.model
            let prompt = launchPlan.request.userSystemPrompt ?? launchPlan.request.prompt ?? parent.systemPrompt
            let rawMeta = launchPlan.request.metadata ?? parent.metadata
            let meta = metadataBySettingSubAgentDepth(
                rawMeta,
                depth: parentDepth + 1,
                lifecycleID: lifecycleID,
                delegateToolName: launchPlan.delegationContext.delegateToolName,
                asyncHandleID: launchPlan.asyncHandleID,
                rootConversationID: rootConversationID,
                pathSegments: lifecyclePathSegments,
                transportKind: launchPlan.delegationContext.transportKind,
                sessionHandleID: launchPlan.delegationContext.resolvedAgentID ?? launchPlan.delegationContext.delegateToolName ?? lifecycleID,
                completionHandleID: launchPlan.asyncHandleID,
                routingContext: launchPlan.request.routingContext
            )
            let (interactionMode, modeProfileIDForChild) = await childInteractionModeAndProfileID(
                launchPlan: launchPlan,
                parentProfile: parentProfile
            )
            let derivedTopic = launchPlan.request.topic ?? launchPlan.request.taskDescription
            let newConv = try await deps.persistenceDomain.createIsolatedSubAgent(
                parentConversationID: parentConversationID,
                selectedModel: model,
                userSystemPrompt: prompt,
                topic: derivedTopic,
                description: launchPlan.request.description,
                metadata: meta,
                interactionMode: interactionMode,
                modeProfileID: modeProfileIDForChild
            )
            guard let child = await deps.persistenceDomain.modelConversation(id: newConv.id) else {
                throw ConversationServiceError.conversationNotFound
            }
            await messaging.update(conversation: child)
            await linkDelegateCost(childConversationID: newConv.id, parentConversationID: parentConversationID)
            if let handleID = launchPlan.asyncHandleID {
                await subAgentPool.completionHandoffOwner.registerBackgroundLaunch(
                    handleID: handleID,
                    conversationID: newConv.id,
                    parentConversationID: parentConversationID
                )
                await completionService.registerHandleOwnership(
                    conversationID: newConv.id,
                    sessionHandleID: launchPlan.delegationContext.resolvedAgentID ?? launchPlan.delegationContext.delegateToolName ?? lifecycleID,
                    completionHandleID: handleID
                )
                var background = admitted
                background.phase = SubAgentLifecyclePhase.completing
                background.childConversationID = newConv.id
                background.updatedAt = Date()
                await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: background)
                await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            } else {
                var running = admitted
                running.phase = SubAgentLifecyclePhase.running
                running.childConversationID = newConv.id
                running.updatedAt = Date()
                await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: running)
                await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            }
            if !launchPlan.request.runInBackground {
                try? await orchestrator.adoptPersistedNewConversationSelection(newConv)
            }
            runLaneHandoffCommitted = true
            return newConv.id
        }
    }

    private func cancelChildRunForSubAgent(childConversationID: UUID) async {
        if let conversation = await deps.persistenceDomain.modelConversation(id: childConversationID),
           let runID = conversation.currentRunID {
            await agentRuntime.cancelSubAgentRun(conversationID: childConversationID, runID: runID)
            return
        }
        let lifecycle = await agentRuntime.lifecycleSnapshot(for: childConversationID)
        guard lifecycle.activeStreamingConversationID == childConversationID,
              let runID = lifecycle.currentStreamingRunID
        else { return }
        try? await agentRuntime.cancelActiveRunForAPI(conversationID: childConversationID, runID: runID)
    }

    func lifecycleSnapshot(parentConversationID: UUID) -> SubAgentLifecycleTopicPayload {
        subAgentLifecycleState.snapshot(parentConversationID: parentConversationID)
    }

    func lifecycleSnapshot(conversationID: UUID, pathSegments: [String]) -> SubAgentLifecycleTopicPayload {
        subAgentLifecycleState.snapshot(conversationID: conversationID, pathSegments: pathSegments)
    }

    func listActiveInvocations(parentConversationID: UUID) -> [ActiveSubAgentInvocationInfo] {
        subAgentLifecycleState.listActiveInvocations(parentConversationID: parentConversationID)
    }

    func cancelActiveInvocationsForParent(parentConversationID: UUID) async {
        for invocation in listActiveInvocations(parentConversationID: parentConversationID) {
            try? await cancelInvocation(
                parentConversationID: parentConversationID,
                lifecycleID: invocation.lifecycleID
            )
        }
    }

    func cancelInvocation(parentConversationID: UUID, lifecycleID: String) async throws {
        guard let entry = subAgentLifecycleState.entry(
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID
        ) else {
            throw ConversationServiceError.conversationNotFound
        }

        if let childConversationID = entry.childConversationID {
            await cancelChildRunForSubAgent(childConversationID: childConversationID)
        } else if let context = subAgentLifecycleState.transportContext(lifecycleID: lifecycleID) {
            let transportCancelResult = try? await subAgentPool.cancelTransport(
                SubAgentTransportCancellationRequest(
                    lifecycleID: lifecycleID,
                    transportKind: context.transportKind,
                    sessionHandleID: context.sessionHandleID,
                    completionHandleID: context.completionHandleID
                )
            )
            for event in transportCancelResult?.delegateEvents ?? [] {
                await applySubAgentDelegateEvent(event)
            }
        }

        var cancelled = entry
        cancelled.phase = .failed
        cancelled.error = "cancelled_by_operator"
        cancelled.updatedAt = Date()
        await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: cancelled)
        await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
    }

    func applySubAgentDelegateEvent(_ event: SubAgentDelegateEvent) async {
        let existing = subAgentLifecycleState
            .entries(parentConversationID: event.parentConversationID)
            .first(where: { $0.lifecycleID == event.lifecycleID })
        let transportContext = subAgentLifecycleState.transportContext(lifecycleID: event.lifecycleID)
        let translated = subAgentDelegateEventTranslator.translate(event: event, existingEntry: existing)
        await upsertSubAgentLifecycleEntry(
            parentConversationID: event.parentConversationID,
            entry: translated.lifecycleEntry
        )
        await publishSubAgentLifecycleIfConfigured(parentConversationID: event.parentConversationID)
        if var runtimeLifecycleEvent = translated.runtimeLifecycleEvent {
            runtimeLifecycleEvent.originTrustLevel = runtimeLifecycleEvent.originTrustLevel
                ?? translated.lifecycleEntry.eventTrustLevel
                ?? translated.lifecycleEntry.defaultTrustLevel
            await topics.publishRuntimeLifecycleEvent(runtimeLifecycleEvent)
        }
        await maybeIngestRemoteTerminalCompletion(
            event: event,
            lifecycleEntry: translated.lifecycleEntry,
            transportContext: transportContext
        )
    }

    private func maybeIngestRemoteTerminalCompletion(
        event: SubAgentDelegateEvent,
        lifecycleEntry: SubAgentLifecycleEntryPayload,
        transportContext: SubAgentLifecycleState.TransportContext?
    ) async {
        guard event.phase == .done || event.phase == .failed else { return }
        guard event.completionAnnounceID == nil else { return }
        guard let transportContext, transportContext.transportKind != .inProcess else { return }

        let delegateHandleID = event.asyncHandleID ?? event.lifecycleID
        let toolCallID = event.toolCallID ?? delegateHandleID
        let conversationID = event.childConversationID ?? event.parentConversationID
        let parentConversationID: UUID?
        if event.childConversationID != nil {
            parentConversationID = event.parentConversationID
        } else {
            parentConversationID = await deps.persistenceDomain.modelConversation(id: conversationID)?.parentConversationID
        }

        let announce = CompletionAnnouncePayload(
            delegateHandleID: delegateHandleID,
            toolCallID: toolCallID,
            conversationID: conversationID,
            parentConversationID: parentConversationID,
            lifecycleID: event.lifecycleID,
            status: event.phase == .done ? .done : .failed,
            completedAt: event.updatedAt,
            source: "subAgentPool.remoteDelegate",
            usage: lifecycleEntry.completionUsage,
            error: event.error
        )
        await completionService.ingestCompletionAnnouncementForAPI(announce, toolMessageContent: nil)
    }

    func applySubAgentTransportPermissionResolutionIfNeeded(
        conversationID: UUID,
        toolName: String,
        route: ToolApprovalRoute,
        status: ToolApprovalResolutionStatus,
        source: String
    ) async {
        let decision: SubAgentTransportPermissionDecision? = switch status {
        case .approved: .approved
        case .denied: .denied
        case .pending: nil
        }
        guard let decision else { return }

        if let parsed = SubAgentACPPermissionToolName.parse(toolName) {
            await SubAgentACPPermissionCoordinator.shared.applyResolution(
                lifecycleID: parsed.lifecycleID,
                requestID: parsed.requestID,
                decision: decision,
                approvalRoute: route,
                optionId: nil
            )
            return
        }

        let activePhases: Set<SubAgentLifecyclePhase> = [.awaitingApproval, .dispatching, .running, .completing]
        guard let entry = subAgentLifecycleState.entries(parentConversationID: conversationID).first(where: {
            $0.delegateToolName == toolName && activePhases.contains($0.phase)
        }) else { return }
        guard let context = subAgentLifecycleState.transportContext(lifecycleID: entry.lifecycleID),
              context.transportKind != .inProcess else {
            return
        }
        let result = try? await subAgentPool.resolveTransportPermission(
            SubAgentTransportPermissionResolutionRequest(
                lifecycleID: entry.lifecycleID,
                transportKind: context.transportKind,
                sessionHandleID: context.sessionHandleID,
                completionHandleID: context.completionHandleID,
                parentConversationID: conversationID,
                approvalRoute: route,
                decision: decision,
                source: source
            )
        )
        guard let result else { return }
        if let correlation = result.correlation {
            subAgentLifecycleState.setTransportContext(
                lifecycleID: entry.lifecycleID,
                context: .init(
                    transportKind: correlation.transportKind,
                    sessionHandleID: correlation.sessionHandleID,
                    completionHandleID: correlation.completionHandleID
                )
            )
            await completionService.registerHandleOwnership(
                conversationID: conversationID,
                sessionHandleID: correlation.sessionHandleID,
                completionHandleID: correlation.completionHandleID
            )
        }
        for event in result.delegateEvents {
            await applySubAgentDelegateEvent(event)
        }
    }

    func rebuildSubAgentLifecycleFromPersistedConversations() async {
        subAgentLifecycleState.reset()
        for conversation in await deps.persistenceDomain.listConversationInfo() {
            guard let parentConversationID = conversation.parentConversationID else { continue }
            await linkDelegateCost(childConversationID: conversation.id, parentConversationID: parentConversationID)
            guard let metadata = conversation.metadata,
                  case .object(let object) = metadata,
                  let lifecycleRaw = object["subAgentLifecycleID"]?.literalValue as? String,
                  !lifecycleRaw.isEmpty else {
                continue
            }
            let handleID = object["subAgentAsyncHandleID"]?.literalValue as? String
            let delegateToolName = object["subAgentDelegateToolName"]?.literalValue as? String
            let restoredTransportKind = SubAgentTransportKind(rawOrAlias: object["subAgentTransportKind"]?.literalValue as? String)
            let restoredSessionHandleID = (object["subAgentSessionHandleID"]?.literalValue as? String) ?? delegateToolName ?? lifecycleRaw
            let restoredCompletionHandleID = (object["subAgentCompletionHandleID"]?.literalValue as? String) ?? handleID
            let rootConversationID: UUID = {
                if let raw = object["subAgentRootConversationID"]?.literalValue as? String,
                   let parsed = UUID(uuidString: raw) {
                    return parsed
                }
                return parentConversationID
            }()
            let pathSegments: [String]
            if let raw = object["subAgentPath"]?.literalValue as? String, !raw.isEmpty {
                pathSegments = raw.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            } else {
                pathSegments = await assignSubAgentPathSegments(
                    lifecycleID: lifecycleRaw,
                    rootConversationID: rootConversationID,
                    parentConversationID: parentConversationID
                )
            }
            subAgentLifecycleState.registerRestoredLifecycle(
                lifecycleID: lifecycleRaw,
                pathSegments: pathSegments,
                rootConversationID: rootConversationID,
                updatedAt: conversation.updatedAt,
                startedAt: conversation.createdAt
            )
            subAgentLifecycleState.setTransportContext(
                lifecycleID: lifecycleRaw,
                context: .init(
                    transportKind: restoredTransportKind == .unknown ? .inProcess : restoredTransportKind,
                    sessionHandleID: restoredSessionHandleID,
                    completionHandleID: restoredCompletionHandleID
                )
            )
            await completionService.registerHandleOwnership(
                conversationID: conversation.id,
                sessionHandleID: restoredSessionHandleID,
                completionHandleID: restoredCompletionHandleID
            )
            let phase: SubAgentLifecyclePhase = if conversation.currentRunID != nil {
                .running
            } else if handleID != nil {
                .completing
            } else {
                .done
            }
            let entry = SubAgentLifecycleEntryPayload(
                lifecycleID: lifecycleRaw,
                parentConversationID: parentConversationID,
                childConversationID: conversation.id,
                delegateToolName: delegateToolName,
                asyncHandleID: handleID,
                phase: phase,
                approvalRoute: await approvalRouteForConversation(conversationID: parentConversationID),
                updatedAt: conversation.updatedAt
            )
            let parentRunID = await deps.persistenceDomain.modelConversation(id: parentConversationID)?.currentRunID
            let restoredEntry = await reacquireSubAgentLaneSlotIfActive(
                parentConversationID: parentConversationID,
                parentRunID: parentRunID,
                lifecycleID: lifecycleRaw,
                entry: entry
            )
            await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: restoredEntry)
            if restoredEntry.phase == .failed {
                await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
            }
        }
        await publishOrphanedSubAgentNotificationsAfterStartup()
    }

    func publishOrphanedSubAgentNotificationsAfterStartup() async {
        for conversation in await deps.persistenceDomain.listConversationInfo() {
            guard let parentConversationID = conversation.parentConversationID else { continue }
            guard let metadata = conversation.metadata,
                  case .object(let object) = metadata,
                  let lifecycleRaw = object["subAgentLifecycleID"]?.literalValue as? String,
                  !lifecycleRaw.isEmpty else {
                continue
            }
            if let existing = subAgentLifecycleState.entry(
                parentConversationID: parentConversationID,
                lifecycleID: lifecycleRaw
            ), existing.phase == .orphaned {
                continue
            }
            let entries = (try? await deps.persistenceDomain.readTranscriptEntries(
                conversationID: conversation.id,
                request: .full
            )) ?? []
            let hasOrphanMarker = entries.contains {
                $0.harnessTypeRaw == RunLifecycleTranscriptMarkerKind.run_orphaned.rawValue
            }
            guard hasOrphanMarker else { continue }
            let wasCancelled = entries.contains {
                $0.harnessTypeRaw == RunLifecycleTranscriptMarkerKind.run_cancelled.rawValue
            }
            guard !wasCancelled else { continue }
            let delegateToolName = object["subAgentDelegateToolName"]?.literalValue as? String
            let handleID = object["subAgentAsyncHandleID"]?.literalValue as? String
            let orphanError = "gateway_restart_orphan"
            let event = SubAgentDelegateEvent(
                lifecycleID: lifecycleRaw,
                parentConversationID: parentConversationID,
                childConversationID: conversation.id,
                delegateToolName: delegateToolName,
                asyncHandleID: handleID,
                phase: .orphaned,
                eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                error: orphanError,
                runtimeLifecycleEvent: RuntimeLifecycleEventPayload(
                    name: .subagentOrphaned,
                    conversationID: parentConversationID,
                    toolName: delegateToolName,
                    policyReason: orphanError,
                    originTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
                    childConversationID: conversation.id,
                    delegateHandleID: lifecycleRaw,
                    toolCallID: handleID,
                    source: "subagent.pool.orphan",
                    updatedAt: Date()
                ),
                updatedAt: Date()
            )
            await applySubAgentDelegateEvent(event)
        }
    }

    func recoverActiveRemoteSubAgentTransportsOnStartup() async {
        let activePhases: Set<SubAgentLifecyclePhase> = [.queued, .dispatching, .running, .awaitingApproval, .completing]
        let entries = subAgentLifecycleState.allEntries().filter { activePhases.contains($0.phase) }
        for entry in entries {
            guard let context = subAgentLifecycleState.transportContext(lifecycleID: entry.lifecycleID),
                  context.transportKind != .inProcess
            else { continue }
            let request = SubAgentTransportRecoveryRequest(
                lifecycleID: entry.lifecycleID,
                transportKind: context.transportKind,
                sessionHandleID: context.sessionHandleID,
                completionHandleID: context.completionHandleID
            )
            let result = try? await subAgentPool.recoverTransport(request)
            guard let result else { continue }
            if let correlation = result.correlation {
                subAgentLifecycleState.setTransportContext(
                    lifecycleID: entry.lifecycleID,
                    context: .init(
                        transportKind: correlation.transportKind,
                        sessionHandleID: correlation.sessionHandleID,
                        completionHandleID: correlation.completionHandleID
                    )
                )
                await completionService.registerHandleOwnership(
                    conversationID: entry.parentConversationID,
                    sessionHandleID: correlation.sessionHandleID,
                    completionHandleID: correlation.completionHandleID
                )
            }
            for event in result.delegateEvents {
                await applySubAgentDelegateEvent(event)
            }
            switch result.disposition {
            case .noAction, .resumed:
                continue
            case .cancelled:
                if result.delegateEvents.isEmpty {
                    var failed = entry
                    failed.phase = .failed
                    failed.error = result.note ?? "remote_transport_recovery_cancelled"
                    failed.updatedAt = Date()
                    await upsertSubAgentLifecycleEntry(parentConversationID: entry.parentConversationID, entry: failed)
                    await publishSubAgentLifecycleIfConfigured(parentConversationID: entry.parentConversationID)
                }
            }
        }
    }

    func stopCompletionHandoffOwner() async {
        await subAgentPool.completionHandoffOwner.stop()
    }

    func startCompletionHandoffOwner(
        orchestrator: SwiftAgentKitOrchestrator,
        resolveConversationID: @escaping @Sendable (String, String?) async -> UUID?,
        onCompletion: @escaping @Sendable (SubAgentPendingCompletionEvent) async -> Void
    ) async {
        await subAgentPool.completionHandoffOwner.startListening(
            orchestrator: orchestrator,
            resolveConversationID: resolveConversationID,
            onCompletion: onCompletion
        )
    }

    func upsertSubAgentLifecycleEntry(
        parentConversationID: UUID,
        entry: SubAgentLifecycleEntryPayload
    ) async {
        if subAgentLifecycleState.pathSegments(lifecycleID: entry.lifecycleID) == nil {
            let rootConversationID = await subAgentRootConversationID(for: parentConversationID)
            _ = await assignSubAgentPathSegments(
                lifecycleID: entry.lifecycleID,
                rootConversationID: rootConversationID,
                parentConversationID: parentConversationID
            )
        }
        subAgentLifecycleState.upsert(parentConversationID: parentConversationID, entry: entry)
        await releaseSubAgentLaneSlotIfTerminal(entry)
    }

    private func releaseSubAgentLaneSlotIfTerminal(_ entry: SubAgentLifecycleEntryPayload) async {
        switch entry.phase {
        case .done, .failed, .orphaned:
            await subAgentInvocationLifecycleCoordinator.endInvocation(lifecycleID: entry.lifecycleID)
        default:
            break
        }
    }

    private func reacquireSubAgentLaneSlotIfActive(
        parentConversationID: UUID,
        parentRunID: UUID?,
        lifecycleID: String,
        entry: SubAgentLifecycleEntryPayload
    ) async -> SubAgentLifecycleEntryPayload {
        let activePhases: Set<SubAgentLifecyclePhase> = [.running, .awaitingApproval, .completing]
        guard activePhases.contains(entry.phase) else { return entry }
        do {
            _ = try await subAgentInvocationLifecycleCoordinator.beginInvocation(
                reservation: SubAgentRunReservation(
                    parentConversationID: parentConversationID,
                    parentRunID: parentRunID,
                    lifecycleID: lifecycleID
                )
            )
            return entry
        } catch {
            var failed = entry
            failed.phase = .failed
            failed.error = "lane_admission_failed"
            failed.updatedAt = Date()
            return failed
        }
    }

    func publishSubAgentLifecycleIfConfigured(parentConversationID: UUID) async {
        guard let publisher = await startup.subAgentLifecyclePublisherForRuntime() else { return }
        let entries = subAgentLifecycleState.entries(parentConversationID: parentConversationID)
        for entry in entries {
            guard let rootConversationID = subAgentLifecycleState.rootConversationID(lifecycleID: entry.lifecycleID),
                  let pathSegments = subAgentLifecycleState.pathSegments(lifecycleID: entry.lifecycleID)
            else { continue }
            let payload = subAgentLifecycleState.snapshot(
                conversationID: rootConversationID,
                pathSegments: pathSegments
            )
            await publisher.broadcastSubAgentLifecycleSnapshot(
                conversationID: rootConversationID,
                pathSegments: pathSegments,
                payload: payload
            )
        }
    }

    // MARK: - Private helpers

    private func linkDelegateCost(childConversationID: UUID, parentConversationID: UUID) async {
        guard let delegateCostTracker = deps.delegateCostTracker else { return }
        await delegateCostTracker.linkConversation(
            childConversationID: childConversationID,
            parentConversationID: parentConversationID
        )
    }

    private static let defaultMachineSpawnModeProfileID = "subagent-minimal"

    private func applyChildRoleCapabilities(
        childID: UUID,
        launchPlan: SubAgentLaunchPlan,
        parentProfile: ResolvedModeProfile,
        metadata: JSON
    ) async throws {
        let (interactionMode, modeProfileID) = await childInteractionModeAndProfileID(
            launchPlan: launchPlan,
            parentProfile: parentProfile
        )
        _ = try await deps.persistenceDomain.updateConversationMetadata(
            conversationID: childID,
            topic: nil,
            description: nil,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            skipControlPlaneRevisionBump: false
        )
        if let userSystemPrompt = launchPlan.request.userSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userSystemPrompt.isEmpty {
            _ = try await deps.persistenceDomain.updateConversationModelAndUserPrompt(
                conversationID: childID,
                model: nil,
                userSystemPrompt: userSystemPrompt,
                skipControlPlaneRevisionBump: true
            )
        }
        guard let child = await deps.persistenceDomain.modelConversation(id: childID) else {
            throw ConversationServiceError.conversationNotFound
        }
        await messaging.update(conversation: child)
    }

    private func childInteractionModeAndProfileID(
        launchPlan: SubAgentLaunchPlan,
        parentProfile: ResolvedModeProfile
    ) async -> (InteractionMode, String) {
        if let raw = launchPlan.request.interactionMode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if let parsed = InteractionMode(rawValue: raw) {
                return (parsed, parsed.rawValue)
            }
            if let modeProfile = try? await deps.modeRegistry.resolve(modeId: raw) {
                return (modeProfile.interactionMode, modeProfile.id)
            }
        }
        if let seedId = parentProfile.subAgents.childModeOnSpawnProfileId,
           let modeProfile = try? await deps.modeRegistry.resolve(modeId: seedId) {
            return (modeProfile.interactionMode, modeProfile.id)
        }
        if let modeProfile = try? await deps.modeRegistry.resolve(modeId: Self.defaultMachineSpawnModeProfileID) {
            return (modeProfile.interactionMode, modeProfile.id)
        }
        return (.agent, Self.defaultMachineSpawnModeProfileID)
    }

    private func resolvedModeProfile(for conversation: ModelConversation) async -> ResolvedModeProfile {
        (await deps.modeRegistry.resolveReportingFallback(
            modeId: conversation.modeProfileID ?? conversation.interactionMode.rawValue,
            logger: deps.logger,
            fallbackModeId: InteractionMode.chat.rawValue
        )).profile
    }

    private func conversationDepth(conversationID: UUID) async -> Int {
        var depth = 0
        var cursor = await deps.persistenceDomain.modelConversation(id: conversationID)?.parentConversationID
        var visited: Set<UUID> = [conversationID]
        while let current = cursor, !visited.contains(current) {
            visited.insert(current)
            depth += 1
            cursor = await deps.persistenceDomain.modelConversation(id: current)?.parentConversationID
        }
        return depth
    }

    private func subAgentRootConversationID(for conversationID: UUID) async -> UUID {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID),
              let metadata = conversation.metadata,
              case .object(let object) = metadata,
              let raw = object["subAgentRootConversationID"]?.literalValue as? String,
              let parsed = UUID(uuidString: raw)
        else { return conversationID }
        return parsed
    }

    private func subAgentPathSegments(for conversationID: UUID) async -> [String] {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: conversationID),
              let metadata = conversation.metadata,
              case .object(let object) = metadata,
              let raw = object["subAgentPath"]?.literalValue as? String,
              !raw.isEmpty
        else { return [] }
        return raw
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func assignSubAgentPathSegments(
        lifecycleID: String,
        rootConversationID: UUID,
        parentConversationID: UUID
    ) async -> [String] {
        let parentPathSegments = await subAgentPathSegments(for: parentConversationID)
        return subAgentLifecycleState.assignPathSegments(
            lifecycleID: lifecycleID,
            rootConversationID: rootConversationID,
            parentPathSegments: parentPathSegments
        )
    }

    private func metadataBySettingSubAgentDepth(
        _ metadata: JSON?,
        depth: Int,
        lifecycleID: String,
        delegateToolName: String?,
        asyncHandleID: String?,
        rootConversationID: UUID,
        pathSegments: [String],
        transportKind: SubAgentTransportKind? = nil,
        sessionHandleID: String? = nil,
        completionHandleID: String? = nil,
        routingContext: SubAgentRoutingContext? = nil
    ) -> JSON {
        var object: [String: JSON] = [:]
        if let metadata, case .object(let existing) = metadata {
            object = existing
        }
        object["subAgentDepth"] = .double(Double(max(0, depth)))
        object["subAgentLifecycleID"] = .string(lifecycleID)
        object["subAgentRootConversationID"] = .string(rootConversationID.uuidString.lowercased())
        object["subAgentPath"] = .string(pathSegments.joined(separator: "/"))
        if let delegateToolName {
            object["subAgentDelegateToolName"] = .string(delegateToolName)
        }
        if let asyncHandleID {
            object["subAgentAsyncHandleID"] = .string(asyncHandleID)
        }
        if let transportKind {
            object["subAgentTransportKind"] = .string(transportKind.rawValue)
        }
        if let sessionHandleID, !sessionHandleID.isEmpty {
            object["subAgentSessionHandleID"] = .string(sessionHandleID)
        }
        if let completionHandleID, !completionHandleID.isEmpty {
            object["subAgentCompletionHandleID"] = .string(completionHandleID)
        }
        if let routingContext {
            if let hostPersonaID = routingContext.hostPersonaID, !hostPersonaID.isEmpty {
                object["subAgentHostPersonaID"] = .string(hostPersonaID)
            }
            if !routingContext.authScopeTags.isEmpty {
                object["subAgentAuthScopeTags"] = .array(routingContext.authScopeTags.map { .string($0) })
            }
            if let routingDomain = routingContext.routingDomain, !routingDomain.isEmpty {
                object["subAgentRoutingDomain"] = .string(routingDomain)
            }
            if let tenantScope = routingContext.tenantScope, !tenantScope.isEmpty {
                object["subAgentTenantScope"] = .string(tenantScope)
            }
        }
        return .object(object)
    }

    private func approvalRouteForConversation(conversationID: UUID) async -> ToolApprovalRoute {
        if let conversation = await deps.persistenceDomain.modelConversation(id: conversationID),
           conversation.parentConversationID != nil {
            return .parent
        }
        return .user
    }

    func invokeDelegateToolFromModelTurn(
        call: ToolCallRequest,
        conversationID: UUID,
        runID: UUID?,
        orchestrator: SwiftAgentKitOrchestrator,
        snapshot: RuntimeToolTurnPolicySnapshot
    ) async -> ToolDispatchOutcome {
        guard let toolEntry = snapshot.effectiveEntries.first(where: { $0.name == call.name }),
              subAgentPool.isDelegateTool(entry: toolEntry) else {
            return .denied(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: "Tool dispatch denied: not a delegate tool."
                )
            )
        }
        guard let parentConversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            return .denied(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: "Tool dispatch denied: conversation not found."
                )
            )
        }
        let instructions = delegateInstructions(from: call.arguments)
        let lifecycleID = call.id ?? "model-\(conversationID.uuidString)-\(UUID().uuidString)"
        let launchRequest = SubAgentLaunchRequest(
            context: .isolated,
            taskDescription: instructions,
            subagentType: resolvedTransportKind(for: toolEntry).rawValue,
            runInBackground: false,
            agentID: call.name,
            permissionAlreadyGranted: true
        )
        do {
            let orchestrationEntries = await subAgentPool.refreshSubAgentCatalog(conversationID: conversationID) { [orchestratorRuntime, agentRuntime] _ in
                guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else { return [] }
                return await orchestratorRuntime.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
            }
            let parentProfile = await resolvedModeProfile(for: parentConversation)
            let parentDepth = await conversationDepth(conversationID: conversationID)
            let preparedLaunch = try await subAgentExecutionCoordinator.prepareLaunch(
                parentConversationID: conversationID,
                parentConversation: parentConversation,
                request: SubAgentSpawnRequest(
                    context: .isolated,
                    taskDescription: instructions,
                    subagentType: launchRequest.subagentType,
                    agentID: call.name
                ),
                orchestrationEntries: orchestrationEntries,
                modeSubAgentAllowList: parentProfile.subAgents.allow,
                modeProfileMaxDepth: parentProfile.subAgents.maxDepth,
                parentDepth: parentDepth
            )
            var launchPlan = preparedLaunch.launchPlan
            launchPlan.asyncHandleID = lifecycleID
            launchPlan.request.permissionAlreadyGranted = launchRequest.permissionAlreadyGranted
            guard let registryEntry = preparedLaunch.selectedRegistryEntry,
                  let selectedToolEntry = preparedLaunch.selectedToolEntry else {
                return .denied(
                    AgentLoopToolDispatch.toolResultMessage(
                        toolCallId: call.id,
                        content: "Tool dispatch denied: delegate not resolved."
                    )
                )
            }
            let isLongRunning = registryEntry.longRunning == true || launchPlan.request.runInBackground
            await seedModelTurnLifecycle(
                lifecycleID: lifecycleID,
                parentConversationID: conversationID,
                launchPlan: launchPlan
            )
            let transportResult = try await subAgentPool.invokeSubAgent(
                launchPlan: launchPlan,
                registryEntry: registryEntry,
                toolEntry: selectedToolEntry,
                parentConversationID: conversationID
            )
            for event in transportResult.delegateEvents {
                await applySubAgentDelegateEvent(event)
            }
            guard case let .remoteStarted(correlation) = transportResult.outcome else {
                return .denied(
                    AgentLoopToolDispatch.toolResultMessage(
                        toolCallId: call.id,
                        content: "In-process delegate model-turn dispatch is not supported yet."
                    )
                )
            }
            subAgentLifecycleState.setTransportContext(
                lifecycleID: lifecycleID,
                context: .init(
                    transportKind: correlation.transportKind,
                    sessionHandleID: correlation.sessionHandleID,
                    completionHandleID: correlation.completionHandleID
                )
            )
            if isLongRunning {
                let stream = await subAgentPool.streamDelegateEvents(
                    SubAgentTransportDelegateEventsRequest(
                        correlation: correlation,
                        parentConversationID: conversationID
                    )
                )
                Task { [weak self] in
                    guard let self else { return }
                    for await event in stream {
                        await self.applySubAgentDelegateEvent(event)
                    }
                }
                return .pendingHandle(
                    AgentLoopToolDispatch.toolResultMessage(
                        toolCallId: call.id,
                        content: "Pending delegate handle: \(correlation.completionHandleID ?? correlation.lifecycleID)"
                    )
                )
            }
            if let terminal = await waitForTerminalDelegateEvent(
                correlation: correlation,
                parentConversationID: conversationID
            ) {
                await applySubAgentDelegateEvent(terminal)
                switch terminal.phase {
                case .done:
                    let content = terminal.completionSource ?? "Delegate completed."
                    return .completed(
                        AgentLoopToolDispatch.toolResultMessage(toolCallId: call.id, content: content)
                    )
                case .failed:
                    return .completed(
                        AgentLoopToolDispatch.toolResultMessage(
                            toolCallId: call.id,
                            content: terminal.error ?? "Delegate failed."
                        )
                    )
                default:
                    break
                }
            }
            return .completed(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: "Delegate invocation ended without a terminal result."
                )
            )
        } catch {
            return .denied(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: "Delegate dispatch failed: \(error)"
                )
            )
        }
    }

    private func delegateInstructions(from arguments: JSON) -> String {
        guard case .object(let object) = arguments,
              case .string(let instructions) = object["instructions"] else {
            return ""
        }
        return instructions
    }

    private func resolvedTransportKind(for entry: ToolRegistryEntry) -> SubAgentTransportKind {
        if entry.transportKind == .a2a || entry.source == .a2a { return .a2a }
        let adapterKind = SubAgentTransportKind(rawOrAlias: entry.executionEnvironment.adapterID)
        if adapterKind != .unknown { return adapterKind }
        return .inProcess
    }

    private func seedModelTurnLifecycle(
        lifecycleID: String,
        parentConversationID: UUID,
        launchPlan: SubAgentLaunchPlan
    ) async {
        let entry = SubAgentLifecycleEntryPayload(
            lifecycleID: lifecycleID,
            parentConversationID: parentConversationID,
            childConversationID: nil,
            delegateToolName: launchPlan.delegationContext.delegateToolName,
            asyncHandleID: launchPlan.asyncHandleID,
            phase: .dispatching,
            defaultTrustLevel: launchPlan.delegationContext.effectiveTrustLevel.rawValue,
            permissionPolicy: launchPlan.delegationContext.effectivePermissionPolicy.rawValue
        )
        await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: entry)
        await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
    }

    private func waitForTerminalDelegateEvent(
        correlation: SubAgentTransportInvocationCorrelation,
        parentConversationID: UUID
    ) async -> SubAgentDelegateEvent? {
        let stream = await subAgentPool.streamDelegateEvents(
            SubAgentTransportDelegateEventsRequest(
                correlation: correlation,
                parentConversationID: parentConversationID
            )
        )
        for await event in stream {
            if event.phase == .done || event.phase == .failed {
                return event
            }
            await applySubAgentDelegateEvent(event)
        }
        return nil
    }
}
