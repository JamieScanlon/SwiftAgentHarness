import CryptoKit
import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import SwiftAgentKitSkills

extension SlashCommandDispatchService {
    private func publishSlashRuntimeLifecycle(_ payload: RuntimeLifecycleEventPayload) async {
        await topics.publishRuntimeLifecycleWithFanout(payload)
    }

    func deliverSyntheticSlashAssistantResponse(
        conversationID: UUID,
        content: String,
        surfaceIntents: [ClientSurfaceIntent] = [],
        preserveGeneratingState: Bool = false
    ) async throws -> ChatStreamResponse {
        let synthetic = Message(
            id: UUID(),
            role: .assistant,
            content: content,
            timestamp: Date(),
            toolCalls: []
        )
        do {
            _ = try await messaging.saveMessageToCache(
                synthetic,
                for: conversationID,
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        } catch {
            deps.logger?.warning(
                "[SlashCommandDispatchService] Slash synthetic message: failed to persist: \(String(describing: error))"
            )
        }
        if var convo = await deps.persistenceDomain.modelConversation(id: conversationID) {
            let priorState = convo.state
            let priorAgentic = convo.agenticPhase
            let priorRequest = convo.llmRequestPhase
            convo.messages.append(synthetic)
            convo.turns = await selection.transformedTurns(
                messages: convo.messages,
                interactionMode: convo.interactionMode,
                previousTurns: convo.turns
            )
            if preserveGeneratingState {
                convo.state = priorState
                convo.agenticPhase = priorAgentic
                convo.llmRequestPhase = priorRequest
            } else {
                convo.state = .idle
                convo.agenticPhase = .idle
                convo.llmRequestPhase = nil
            }
            await deps.persistenceDomain.replaceConversationInRegistry(convo)
            await sessionProjection.syncFromRegistry(conversationID: conversationID, conversation: convo)
        }
        let (partialStream, partialContinuation) = AsyncStream.makeStream(
            of: ChatStreamingPartial.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        for intent in surfaceIntents {
            partialContinuation.yield(.surfaceIntent(intent))
            await topics.publishConversationTopicEventIfConfigured(
                conversationID: conversationID,
                payload: ConversationTopicWireEncoding.surfaceIntentPayload(intent: intent)
            )
        }
        partialContinuation.yield(.text(content))
        partialContinuation.finish()
        let (orchestrationStream, orchestrationContinuation) = AsyncStream.makeStream(
            of: ConversationOrchestrationState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        orchestrationContinuation.yield(
            ConversationOrchestrationState(
                llmRuntimePhase: .idleReady,
                agenticPhase: .idle,
                llmRequestPhase: nil
            )
        )
        orchestrationContinuation.finish()
        return ChatStreamResponse(
            partialContent: partialStream,
            orchestrationState: orchestrationStream,
            conversationID: conversationID
        )
    }

    func deliverSyntheticSlashSkillActivation(
        conversationID: UUID,
        skillName: String,
        activationBody: String,
        confirmation: String
    ) async throws -> ChatStreamResponse {
        let toolCallID = UUID().uuidString
        let assistantCall = Message(
            id: UUID(),
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: [
                ToolCall(
                    name: SkillsToolProvider.activateToolName,
                    arguments: .object(["skill_name": .string(skillName)]),
                    id: toolCallID
                ),
            ]
        )
        let toolResult = Message(
            id: UUID(),
            role: .tool,
            content: activationBody,
            timestamp: Date(),
            toolCalls: [],
            toolCallId: toolCallID
        )
        let confirmationMessage = Message(
            id: UUID(),
            role: .assistant,
            content: confirmation,
            timestamp: Date(),
            toolCalls: []
        )
        let transcriptMessages = [assistantCall, toolResult, confirmationMessage]
        for message in transcriptMessages {
            do {
                _ = try await messaging.saveMessageToCache(
                    message,
                    for: conversationID,
                    expectedPreviousTailHarnessMessageID: nil,
                    transcriptRunID: nil
                )
            } catch {
                deps.logger?.warning(
                    "[SlashCommandDispatchService] Slash skill activation message persist failed: \(String(describing: error))"
                )
            }
        }
        if var convo = await deps.persistenceDomain.modelConversation(id: conversationID) {
            convo.messages.append(contentsOf: transcriptMessages)
            convo.turns = await selection.transformedTurns(
                messages: convo.messages,
                interactionMode: convo.interactionMode,
                previousTurns: convo.turns
            )
            convo.state = .idle
            convo.agenticPhase = .idle
            convo.llmRequestPhase = nil
            await deps.persistenceDomain.replaceConversationInRegistry(convo)
            await sessionProjection.syncFromRegistry(conversationID: conversationID, conversation: convo)
        }
        let (partialStream, partialContinuation) = AsyncStream.makeStream(
            of: ChatStreamingPartial.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        partialContinuation.yield(.text(confirmation))
        partialContinuation.finish()
        let (orchestrationStream, orchestrationContinuation) = AsyncStream.makeStream(
            of: ConversationOrchestrationState.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        orchestrationContinuation.yield(
            ConversationOrchestrationState(
                llmRuntimePhase: .idleReady,
                agenticPhase: .idle,
                llmRequestPhase: nil
            )
        )
        orchestrationContinuation.finish()
        return ChatStreamResponse(
            partialContent: partialStream,
            orchestrationState: orchestrationStream,
            conversationID: conversationID
        )
    }

    func runSlashToolDispatch(
        conversationID: UUID,
        command: SlashCommand,
        parsed: ParsedSlashCommand,
        rawText: String
    ) async throws -> ChatStreamResponse {
        guard case let .toolDispatch(toolName, argMode) = command.kind else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Invalid slash dispatch configuration for `\(command.base.name)`."
            )
        }
        guard var conversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        await orchestratorRuntime.setupOrchestrator(with: conversation.model, activeConversation: conversation)
        guard let orchestrator = await agentRuntime.orchestrator(for: conversationID) else {
            throw ConversationServiceError.failedToInitialize
        }
        let entries = await orchestratorRuntime.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
        guard let entry = entries.first(where: { $0.name == toolName }) else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Slash command `\(command.base.name)` maps to unknown tool `\(toolName)`."
            )
        }
        let dispatchContext = executionDispatchContext(for: entry)
        let policyConfiguration = await toolApproval.configurationApplyingToolApprovals(
            configurationApplyingTrustPolicy(HarnessRuntimeSession.Configuration()),
            conversationID: conversationID,
            runID: conversation.currentRunID
        )
        let modeCtx = await modePolicyContext(for: conversation)
        let runtimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: policyConfiguration)
        let decision = toolSystemGateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: runtimeConfiguration,
            toolPolicy: deps.toolPolicy,
            trustPolicy: deps.trustPolicyConfiguration,
            subAgentToolClassifier: subAgentPool
        )
        if decision.blockReason == .approvalRequired {
            return try await runSlashToolDispatchAfterApproval(
                conversationID: conversationID,
                conversation: &conversation,
                command: command,
                parsed: parsed,
                rawText: rawText,
                argMode: argMode,
                toolName: toolName,
                entry: entry,
                dispatchContext: dispatchContext,
                decision: decision,
                orchestrator: orchestrator,
                modeCtx: modeCtx
            )
        }
        if !decision.allowed {
            let reason = decision.blockReason?.rawValue ?? "blocked"
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool dispatch blocked by policy (`\(reason)`)."
            )
        }
        return try await executeSlashToolInvocation(
            conversationID: conversationID,
            conversation: conversation,
            command: command,
            parsed: parsed,
            rawText: rawText,
            argMode: argMode,
            toolName: toolName,
            entry: entry,
            decision: decision,
            dispatchContext: dispatchContext,
            orchestrator: orchestrator,
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private func runSlashToolDispatchAfterApproval(
        conversationID: UUID,
        conversation: inout ModelConversation,
        command: SlashCommand,
        parsed: ParsedSlashCommand,
        rawText: String,
        argMode: SlashToolDispatchArgMode,
        toolName: String,
        entry: ToolRegistryEntry,
        dispatchContext: SlashExecutionDispatchContext,
        decision: ToolAvailabilityDecision,
        orchestrator: SwiftAgentKitOrchestrator,
        modeCtx: ModePolicyContext
    ) async throws -> ChatStreamResponse {
        let route = decision.approvalRoute ?? .user
        let invocationRequest = slashToolInvocationRequest(
            conversation: conversation,
            command: command,
            parsed: parsed,
            rawText: rawText,
            argMode: argMode,
            toolName: toolName,
            decision: decision,
            dispatchContext: dispatchContext
        )
        let argumentProvenance = slashArgumentProvenance(
            invocationRequest: invocationRequest,
            rawText: rawText
        )
        let spec = toolApproval.approvalContractSpec(
            toolName: toolName,
            route: route,
            isElevated: decision.isElevated,
            arguments: invocationRequest.argumentsPayload
        )
        let approvalCall = ToolCallRequest(
            id: invocationRequest.toolCallID,
            name: toolName,
            arguments: ToolCallApprovalBinding.orchestratorPolicyArguments(for: invocationRequest)
        )
        _ = await toolApproval.registerPendingToolApproval(
            conversationID: conversationID,
            runID: conversation.currentRunID,
            call: approvalCall,
            route: route,
            isElevated: decision.isElevated
        )
        await publishSlashRuntimeLifecycle(
            RuntimeLifecycleEventPayload(
                name: .toolApprovalRequired,
                conversationID: conversationID,
                runID: conversation.currentRunID,
                toolName: toolName,
                approvalState: .pending,
                policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                approvalRoute: route,
                approvalTitle: spec.title,
                approvalDescription: spec.description,
                approvalSeverity: spec.severity,
                approvalTimeoutMs: spec.timeoutMs,
                approvalTimeoutBehavior: spec.timeoutBehavior.rawValue,
                approvalResolutionKind: ToolApprovalResolutionKind.runtimeAuto.rawValue,
                toolCallID: invocationRequest.toolCallID,
                argumentDigest: argumentProvenance?.digest,
                argumentByteCount: argumentProvenance?.byteCount,
                argumentRedaction: argumentProvenance?.redaction,
                executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                executionIsolationLevel: dispatchContext.executionIsolationLevel,
                source: "slash.toolDispatch"
            )
        )
        let binding = ToolCallApprovalBinding.from(call: approvalCall)
        let resolution: ToolApprovalResolution
        do {
            resolution = try await toolApproval.waitForToolApprovalResolution(
                conversationID: conversationID,
                runID: conversation.currentRunID,
                binding: binding,
                route: route
            )
        } catch {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool dispatch denied: approval cancelled."
            )
        }
        if resolution.kind == .timeoutDefault {
            let approvalState: RuntimeLifecycleApprovalState = resolution.status == .approved ? .approved : .denied
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolApprovalResolved,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    approvalState: approvalState,
                    policyReason: ToolAvailabilityBlockReason.approvalRequired.rawValue,
                    approvalSource: resolution.source,
                    approvalReason: resolution.reason,
                    approvalRoute: route,
                    approvalTitle: spec.title,
                    approvalDescription: spec.description,
                    approvalSeverity: spec.severity,
                    approvalTimeoutMs: spec.timeoutMs,
                    approvalTimeoutBehavior: spec.timeoutBehavior.rawValue,
                    approvalResolutionKind: resolution.kind.rawValue,
                    toolCallID: invocationRequest.toolCallID,
                    source: "slash.approvalTimeout"
                )
            )
        }
        switch resolution.status {
        case .approved:
            let approvedConfiguration = await toolApproval.configurationApplyingToolApprovals(
                configurationApplyingTrustPolicy(HarnessRuntimeSession.Configuration()),
                conversationID: conversationID,
                runID: conversation.currentRunID
            )
            let approvedRuntimeConfiguration = AgentRuntimeTurnConfiguration(managerConfiguration: approvedConfiguration)
            guard let refreshedConversation = await deps.persistenceDomain.modelConversation(id: conversationID) else {
                return try await deliverSyntheticSlashAssistantResponse(
                    conversationID: conversationID,
                    content: "Tool dispatch denied: conversation not found."
                )
            }
            conversation = refreshedConversation
            let refreshedDecision = toolSystemGateway.evaluateAvailability(
                entry: entry,
                conversation: conversation,
                modePolicyContext: modeCtx,
                configuration: approvedRuntimeConfiguration,
                toolPolicy: deps.toolPolicy,
                trustPolicy: deps.trustPolicyConfiguration,
                subAgentToolClassifier: subAgentPool
            )
            let bindingPreApproved = ToolCallApprovalPolicy.isBindingPreApproved(
                call: approvalCall,
                configuration: approvedRuntimeConfiguration
            )
            guard refreshedDecision.allowed || bindingPreApproved else {
                let reason = refreshedDecision.blockReason?.rawValue ?? "blocked"
                return try await deliverSyntheticSlashAssistantResponse(
                    conversationID: conversationID,
                    content: "Tool dispatch blocked after approval (`\(reason)`)."
                )
            }
            return try await executeSlashToolInvocation(
                conversationID: conversationID,
                conversation: conversation,
                command: command,
                parsed: parsed,
                rawText: rawText,
                argMode: argMode,
                toolName: toolName,
                entry: entry,
                decision: refreshedDecision,
                dispatchContext: dispatchContext,
                orchestrator: orchestrator,
                runtimeConfiguration: approvedRuntimeConfiguration,
                invocationRequest: invocationRequest,
                argumentProvenance: argumentProvenance
            )
        case .denied, .pending:
            let denyContent: String
            if ToolNamePolicyNormalization.canonical(toolName)
                == ModeTransitionToolProvider.exitPlanModeToolName,
               resolution.status == .denied
            {
                denyContent = PlanApprovalFeedback.deniedToolResultContent(reason: resolution.reason)
            } else {
                denyContent = "Tool dispatch denied."
            }
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: denyContent
            )
        }
    }

    private func executeSlashToolInvocation(
        conversationID: UUID,
        conversation: ModelConversation,
        command: SlashCommand,
        parsed: ParsedSlashCommand,
        rawText: String,
        argMode: SlashToolDispatchArgMode,
        toolName: String,
        entry: ToolRegistryEntry,
        decision: ToolAvailabilityDecision,
        dispatchContext: SlashExecutionDispatchContext,
        orchestrator: SwiftAgentKitOrchestrator,
        runtimeConfiguration: AgentRuntimeTurnConfiguration,
        invocationRequest: ToolInvocationRequest? = nil,
        argumentProvenance: HarnessRuntimeSession.ToolPayloadProvenance? = nil
    ) async throws -> ChatStreamResponse {
        let request = invocationRequest ?? slashToolInvocationRequest(
            conversation: conversation,
            command: command,
            parsed: parsed,
            rawText: rawText,
            argMode: argMode,
            toolName: toolName,
            decision: decision,
            dispatchContext: dispatchContext
        )
        let provenance = argumentProvenance ?? slashArgumentProvenance(
            invocationRequest: request,
            rawText: rawText
        )
        await publishSlashRuntimeLifecycle(
            RuntimeLifecycleEventPayload(
                name: .toolCallStarted,
                conversationID: conversationID,
                runID: conversation.currentRunID,
                toolName: toolName,
                toolCallID: request.toolCallID,
                argumentDigest: provenance?.digest,
                argumentByteCount: provenance?.byteCount,
                argumentRedaction: provenance?.redaction,
                executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                executionIsolationLevel: dispatchContext.executionIsolationLevel,
                source: "slash.toolDispatch"
            )
        )
        if let spawnService = subAgentSpawnService,
           subAgentPool.isDelegateTool(entry: entry) {
            let snapshot = RuntimeToolTurnPolicySnapshot(
                availabilitySnapshots: [RuntimeToolAvailabilitySnapshot(entry: entry, decision: decision)],
                effectiveEntries: [entry],
                dispatchContract: toolSystemGateway.dispatchContract(
                    from: deps.toolPolicy,
                    effectiveEntries: decision.allowed ? [entry] : []
                )
            )
            let call = ToolCallRequest(
                id: request.toolCallID,
                name: toolName,
                arguments: request.argumentsPayload
            )
            let delegateOutcome = await spawnService.invokeDelegateToolFromModelTurn(
                call: call,
                conversationID: conversationID,
                runID: conversation.currentRunID,
                orchestrator: orchestrator,
                snapshot: snapshot
            )
            return try await deliverSlashDelegateOutcome(
                delegateOutcome,
                conversationID: conversationID,
                conversation: conversation,
                toolName: toolName,
                request: request,
                provenance: provenance,
                dispatchContext: dispatchContext,
                decision: decision
            )
        }
        let outcome = await orchestrator.invokeTool(request)
        switch outcome {
        case .completed(let result, _):
            let resultProvenance = HarnessRuntimeSession.toolPayloadProvenance(
                text: result.success ? result.content : (result.error ?? "Tool execution failed."),
                redaction: "resultDigestOnly"
            )
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    policyReason: result.success ? nil : "tool_error",
                    toolCallID: request.toolCallID,
                    argumentDigest: provenance?.digest,
                    argumentByteCount: provenance?.byteCount,
                    argumentRedaction: provenance?.redaction,
                    resultDigest: resultProvenance?.digest,
                    resultByteCount: resultProvenance?.byteCount,
                    resultRedaction: resultProvenance?.redaction,
                    resultTruncated: result.success ? nil : false,
                    executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                    executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                    executionIsolationLevel: dispatchContext.executionIsolationLevel,
                    source: "slash.toolDispatch"
                )
            )
            let content = result.success ? result.content : (result.error ?? "Tool execution failed.")
            if decision.isElevated, result.success {
                await publishSlashRuntimeLifecycle(
                    RuntimeLifecycleEventPayload(
                        name: .toolElevatedExecuted,
                        conversationID: conversationID,
                        runID: conversation.currentRunID,
                        toolName: toolName,
                        policyReason: deps.toolPolicy.elevatedExecutionPolicy.rawValue,
                        source: "slash.elevatedExecution"
                    )
                )
            }
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: content
            )
        case .pending(let handle, _):
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    policyReason: "pending",
                    delegateHandleID: handle.handleID,
                    toolCallID: request.toolCallID,
                    argumentDigest: provenance?.digest,
                    argumentByteCount: provenance?.byteCount,
                    argumentRedaction: provenance?.redaction,
                    executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                    executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                    executionIsolationLevel: dispatchContext.executionIsolationLevel,
                    source: "slash.toolDispatch"
                )
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool `\(toolName)` accepted and running asynchronously (handle: \(handle.handleID))."
            )
        case .denied:
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    policyReason: "denied",
                    toolCallID: request.toolCallID,
                    argumentDigest: provenance?.digest,
                    argumentByteCount: provenance?.byteCount,
                    argumentRedaction: provenance?.redaction,
                    executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                    executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                    executionIsolationLevel: dispatchContext.executionIsolationLevel,
                    source: "slash.toolDispatch"
                )
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool dispatch denied by pre-dispatch policy."
            )
        case .approvalRequired:
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool dispatch requires approval before execution."
            )
        }
    }

    private func deliverSlashDelegateOutcome(
        _ outcome: ToolDispatchOutcome,
        conversationID: UUID,
        conversation: ModelConversation,
        toolName: String,
        request: ToolInvocationRequest,
        provenance: HarnessRuntimeSession.ToolPayloadProvenance?,
        dispatchContext: SlashExecutionDispatchContext,
        decision: ToolAvailabilityDecision
    ) async throws -> ChatStreamResponse {
        switch outcome {
        case .completed(let message):
            let resultProvenance = HarnessRuntimeSession.toolPayloadProvenance(
                text: message.content,
                redaction: "resultDigestOnly"
            )
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    toolCallID: request.toolCallID,
                    argumentDigest: provenance?.digest,
                    argumentByteCount: provenance?.byteCount,
                    argumentRedaction: provenance?.redaction,
                    resultDigest: resultProvenance?.digest,
                    resultByteCount: resultProvenance?.byteCount,
                    resultRedaction: resultProvenance?.redaction,
                    executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                    executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                    executionIsolationLevel: dispatchContext.executionIsolationLevel,
                    source: "slash.toolDispatch"
                )
            )
            if decision.isElevated {
                await publishSlashRuntimeLifecycle(
                    RuntimeLifecycleEventPayload(
                        name: .toolElevatedExecuted,
                        conversationID: conversationID,
                        runID: conversation.currentRunID,
                        toolName: toolName,
                        policyReason: deps.toolPolicy.elevatedExecutionPolicy.rawValue,
                        source: "slash.elevatedExecution"
                    )
                )
            }
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: message.content
            )
        case .pendingHandle(let message):
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    policyReason: "pending",
                    toolCallID: request.toolCallID,
                    argumentDigest: provenance?.digest,
                    argumentByteCount: provenance?.byteCount,
                    argumentRedaction: provenance?.redaction,
                    executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                    executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                    executionIsolationLevel: dispatchContext.executionIsolationLevel,
                    source: "slash.toolDispatch"
                )
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: message.content
            )
        case .denied(let message):
            await publishSlashRuntimeLifecycle(
                RuntimeLifecycleEventPayload(
                    name: .toolCallCompleted,
                    conversationID: conversationID,
                    runID: conversation.currentRunID,
                    toolName: toolName,
                    policyReason: "denied",
                    toolCallID: request.toolCallID,
                    argumentDigest: provenance?.digest,
                    argumentByteCount: provenance?.byteCount,
                    argumentRedaction: provenance?.redaction,
                    executionEnvironmentKind: dispatchContext.executionEnvironmentKind,
                    executionEnvironmentAdapterID: dispatchContext.executionEnvironmentAdapterID,
                    executionIsolationLevel: dispatchContext.executionIsolationLevel,
                    source: "slash.toolDispatch"
                )
            )
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: message.content
            )
        case .approvalRequired:
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Tool dispatch requires approval before execution."
            )
        }
    }

    private func slashToolInvocationRequest(
        conversation: ModelConversation,
        command: SlashCommand,
        parsed: ParsedSlashCommand,
        rawText: String,
        argMode: SlashToolDispatchArgMode,
        toolName: String,
        decision: ToolAvailabilityDecision,
        dispatchContext: SlashExecutionDispatchContext
    ) -> ToolInvocationRequest {
        ToolInvocationRequest(
            toolName: toolName,
            argumentsPayload: slashToolInvocationArguments(parsed: parsed, argMode: argMode),
            argumentMode: slashToolInvocationArgumentMode(argMode),
            rawEnvelope: slashRawEnvelope(parsed: parsed, rawText: rawText, argMode: argMode),
            conversationID: conversation.id.uuidString,
            runID: conversation.currentRunID?.uuidString,
            source: .command,
            callerProvenance: "slash:\(command.base.name)",
            policyContext: .object([
                "slashCommand": .string(command.base.name),
                "commandName": .string(parsed.name),
                "args": .string(parsed.args),
                "executionEnvironmentKind": .string(dispatchContext.executionEnvironmentKind),
                "executionEnvironmentAdapterID": .string(dispatchContext.executionEnvironmentAdapterID),
                "executionIsolationLevel": .string(dispatchContext.executionIsolationLevel),
                "executionPolicy": .string(
                    decision.isElevated
                        ? deps.toolPolicy.elevatedExecutionPolicy.rawValue
                        : "standard"
                ),
            ]),
            timeoutSeconds: deps.toolPolicy.pendingToolTimeoutSeconds
        )
    }

    private func slashArgumentProvenance(
        invocationRequest: ToolInvocationRequest,
        rawText: String
    ) -> HarnessRuntimeSession.ToolPayloadProvenance? {
        HarnessRuntimeSession.toolPayloadProvenance(
            json: invocationRequest.argumentsPayload,
            redaction: "commandArgumentsDigestOnly"
        ) ?? HarnessRuntimeSession.toolPayloadProvenance(
            text: rawText,
            redaction: "rawCommandDigestOnly"
        )
    }

    private struct SlashExecutionDispatchContext: Sendable {
        let executionEnvironmentKind: String
        let executionEnvironmentAdapterID: String
        let executionIsolationLevel: String
    }

    private func executionDispatchContext(for entry: ToolRegistryEntry) -> SlashExecutionDispatchContext {
        SlashExecutionDispatchContext(
            executionEnvironmentKind: entry.executionEnvironment.kind.rawValue,
            executionEnvironmentAdapterID: entry.executionEnvironment.adapterID,
            executionIsolationLevel: entry.executionEnvironment.isolationLevel.rawValue
        )
    }

    func modePolicyContext(for conversation: ModelConversation) async -> ModePolicyContext {
        let profile = await ContextEngineProjectionPolicyBuilder.resolvedModeProfile(
            for: conversation,
            modeRegistry: deps.modeRegistry,
            logger: deps.logger
        )
        return ModePolicyContext(conversation: conversation, resolvedProfile: profile)
    }

    func configurationApplyingTrustPolicy(
        _ configuration: HarnessRuntimeSession.Configuration
    ) -> HarnessRuntimeSession.Configuration {
        var out = configuration
        out.inputTrustRaw = MessageInputTrustCodec.sanitizedInputTrustRaw(configuration.inputTrustRaw)
        let trustClass = configuration.resolvedInputTrustClass
            ?? MessageInputTrustCodec.safePolicyClass(
                raw: out.inputTrustRaw,
                unknownFallback: deps.trustPolicyConfiguration.safeDefaultClass
            )
        out.resolvedInputTrustClass = trustClass
        if deps.trustPolicyConfiguration.shouldGateExecution(for: trustClass) {
            out.enableTools = false
            out.enableAgents = false
        }
        return out
    }

    private func slashToolInvocationArgumentMode(_ argMode: SlashToolDispatchArgMode) -> ToolInvocationArgumentMode {
        switch argMode {
        case .raw:
            return .raw
        case .parsed:
            return .parsed
        }
    }

    private func slashToolInvocationArguments(
        parsed: ParsedSlashCommand,
        argMode: SlashToolDispatchArgMode
    ) -> JSON {
        switch argMode {
        case .raw:
            return .object([:])
        case .parsed:
            return .object([
                "commandName": .string(parsed.name),
                "args": .string(parsed.args),
            ])
        }
    }

    private func slashRawEnvelope(
        parsed: ParsedSlashCommand,
        rawText: String,
        argMode: SlashToolDispatchArgMode
    ) -> RawToolCommandEnvelope? {
        guard argMode == .raw else { return nil }
        let tokens = parsed.args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return RawToolCommandEnvelope(
            envelopeVersion: "1",
            rawText: rawText,
            commandToken: "/\(parsed.name)",
            commandName: parsed.name,
            argsText: parsed.args,
            parsedTokens: tokens
        )
    }
}
