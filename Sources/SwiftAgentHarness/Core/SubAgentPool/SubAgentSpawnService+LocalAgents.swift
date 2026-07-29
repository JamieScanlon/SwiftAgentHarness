import EasyJSON
import Foundation
import SwiftAgentKit

/// Blocking child-run dispatch for in-process delegates. Injected at composition time so the spawn
/// service reaches the same embedded-REST-with-runtime-fallback path Memory and Triggers use.
typealias LocalAgentChildRunPort = @Sendable (UUID, String) async throws -> Void

extension SubAgentSpawnService {
    /// Outcome of a blocking in-process delegate run, derived from runtime signals rather than from
    /// whatever the child's assistant text claims.
    enum LocalAgentRunOutcome: Sendable, Equatable {
        case completed(String)
        case failed(String)
        case timedOut(TimeInterval)
        case cancelled
    }

    func localAgentDefinition(forToolName toolName: String) -> LocalAgentDefinition? {
        deps.configurationSet.localAgents.definition(forToolName: toolName)
    }

    /// Full in-process delegate turn: resolve model, spawn an isolated child on the caller's
    /// lifecycle id, drive it to completion, and hand its final report back as the tool result.
    func invokeInProcessLocalAgent(
        call: ToolCallRequest,
        conversationID: UUID,
        parentConversation: ModelConversation,
        toolEntry: ToolRegistryEntry,
        definition: LocalAgentDefinition
    ) async -> ToolDispatchOutcome {
        let lifecycleID = call.id ?? "model-\(conversationID.uuidString)-\(UUID().uuidString)"
        let instructions = Self.delegateInstructions(from: call.arguments)
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .denied(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: "Tool dispatch denied: '\(Self.instructionsArgumentName)' is required and must be non-empty."
                )
            )
        }
        // A nil override leaves `performSpawn` to inherit the parent conversation's model.
        var modelOverride: Model?
        if let modelRef = definition.modelRef {
            guard let resolved = await resolveLocalAgentModel(modelRef) else {
                return .denied(
                    AgentLoopToolDispatch.toolResultMessage(
                        toolCallId: call.id,
                        content: "Tool dispatch denied: delegate '\(definition.displayName)' model '\(modelRef)' did not resolve."
                    )
                )
            }
            modelOverride = resolved
        }
        let label = Self.delegateTaskLabel(from: call.arguments) ?? definition.displayName
        // The agent's configured delivery mode is the default; the model may override per call.
        let runInBackground = Self.delegateRunInBackground(from: call.arguments) ?? definition.longRunning
        let toolCallID = call.id ?? lifecycleID

        let childID: UUID
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
                    taskDescription: label,
                    prompt: instructions,
                    subagentType: SubAgentTransportKind.inProcess.rawValue,
                    agentID: toolEntry.name,
                    runInBackground: runInBackground,
                    topic: label,
                    interactionMode: definition.modeProfileID,
                    toolsAllow: definition.toolsAllow
                ),
                orchestrationEntries: orchestrationEntries,
                modeSubAgentAllowList: parentProfile.subAgents.allow,
                modeProfileMaxDepth: Self.effectiveMaxDepth(
                    modeProfileMaxDepth: parentProfile.subAgents.maxDepth,
                    definitionMaxDepth: definition.maxRecursionDepth
                ),
                parentDepth: parentDepth
            )
            // One prepared launch, one lifecycle row keyed by tool-call id, one run-lane
            // acquisition that the terminal upsert below releases.
            var prepared = preparedLaunch
            if runInBackground {
                // `planLaunch` derives the async handle from `agentID` — the delegate tool name —
                // which collides across concurrent calls to the same agent. Key it to this tool
                // call so completion announcements correlate to the right invocation.
                prepared.launchPlan.asyncHandleID = lifecycleID
            }
            childID = try await performSpawn(
                parentConversationID: conversationID,
                parentConversation: parentConversation,
                parentProfile: parentProfile,
                parentDepth: parentDepth,
                preparedLaunch: prepared,
                modelOverride: modelOverride,
                lifecycleIDOverride: lifecycleID,
                adoptChildSelection: false
            )
        } catch {
            await finishLocalAgentLifecycle(
                lifecycleID: lifecycleID,
                parentConversationID: conversationID,
                childConversationID: nil,
                delegateToolName: toolEntry.name,
                toolCallID: call.id,
                outcome: .failed("\(error)")
            )
            return .denied(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: "Delegate dispatch failed: \(error)"
                )
            )
        }

        guard !runInBackground else {
            // Push-based delivery: hand the model a handle now and announce completion into the
            // parent conversation later, through the same pipeline the remote transports use.
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.runLocalAgentChild(
                    childConversationID: childID,
                    prompt: instructions,
                    timeoutSeconds: definition.runTimeoutSeconds
                )
                await self.finishLocalAgentLifecycle(
                    lifecycleID: lifecycleID,
                    parentConversationID: conversationID,
                    childConversationID: childID,
                    delegateToolName: toolEntry.name,
                    toolCallID: toolCallID,
                    outcome: outcome
                )
                await self.announceLocalAgentCompletion(
                    outcome: outcome,
                    displayName: definition.displayName,
                    parentConversationID: conversationID,
                    lifecycleID: lifecycleID,
                    toolCallID: toolCallID
                )
            }
            return .pendingHandle(
                AgentLoopToolDispatch.toolResultMessage(
                    toolCallId: call.id,
                    content: Self.pendingHandleContent(displayName: definition.displayName, handleID: lifecycleID)
                )
            )
        }

        let outcome = await runLocalAgentChild(
            childConversationID: childID,
            prompt: instructions,
            timeoutSeconds: definition.runTimeoutSeconds
        )
        await finishLocalAgentLifecycle(
            lifecycleID: lifecycleID,
            parentConversationID: conversationID,
            childConversationID: childID,
            delegateToolName: toolEntry.name,
            toolCallID: toolCallID,
            outcome: outcome
        )
        return .completed(
            AgentLoopToolDispatch.toolResultMessage(
                toolCallId: call.id,
                content: Self.toolResultContent(for: outcome, displayName: definition.displayName)
            )
        )
    }

    /// Routes a finished background delegate into the shared completion-announce pipeline, which
    /// owns idempotency (`tryBeginDelivery`), the durable announce marker, tool-message append,
    /// runtime + sub-agent lifecycle publication, and retry with a bounded fallback.
    private func announceLocalAgentCompletion(
        outcome: LocalAgentRunOutcome,
        displayName: String,
        parentConversationID: UUID,
        lifecycleID: String,
        toolCallID: String
    ) async {
        let notification = await makeLocalAgentCompletionNotification(
            outcome: outcome,
            displayName: displayName,
            parentConversationID: parentConversationID,
            toolCallID: toolCallID
        )
        let announce = CompletionAnnouncePayload(
            delegateHandleID: lifecycleID,
            toolCallID: toolCallID,
            // The tool call lives on the parent, so the tool result must land there — not on the
            // child conversation the delegate ran in.
            conversationID: parentConversationID,
            parentConversationID: await deps.persistenceDomain
                .modelConversation(id: parentConversationID)?.parentConversationID,
            lifecycleID: lifecycleID,
            status: outcome.isSuccess ? .done : .failed,
            completedAt: Date(),
            source: "subAgentPool.localAgent",
            error: Self.lifecycleError(for: outcome)
        )
        await completionService.ingestCompletionAnnouncement(announce, notification: notification)
        // Wake-on-idle: no-ops while a turn is running, so a completion landing mid-turn is picked
        // up by that turn rather than racing it.
        await orchestrator.resumeAfterDelegateCompletionIfIdle(conversationID: parentConversationID)
    }

    /// The completion arrives as an ordinary later-turn message, never a second `tool_result` — the
    /// delegate's tool call was already answered by its pending handle.
    private func makeLocalAgentCompletionNotification(
        outcome: LocalAgentRunOutcome,
        displayName: String,
        parentConversationID: UUID,
        toolCallID: String
    ) async -> Message {
        let tail = await deps.persistenceDomain.modelConversation(id: parentConversationID)?.messages.last
        return Message(
            id: UUID(),
            role: Self.completionNotificationRole(followingTailRole: tail?.role),
            content: Self.completionNotificationBody(
                outcome: outcome,
                displayName: displayName,
                toolCallID: toolCallID
            ),
            timestamp: Date()
        )
    }

    /// Providers reject two consecutive same-role messages, so the notification yields to the tail.
    static func completionNotificationRole(followingTailRole: MessageRole?) -> MessageRole {
        followingTailRole == .user ? .assistant : .user
    }

    static func completionNotificationBody(
        outcome: LocalAgentRunOutcome,
        displayName: String,
        toolCallID: String
    ) -> String {
        let status: String = switch outcome {
        case .completed: "completed"
        case .failed: "failed"
        case .timedOut: "timed out"
        case .cancelled: "cancelled"
        }
        return """
        <task-notification>
        <source>subagent</source>
        <agent>\(displayName)</agent>
        <tool-call-id>\(toolCallID)</tool-call-id>
        <status>\(status)</status>
        <result>
        \(Self.toolResultContent(for: outcome, displayName: displayName))
        </result>
        </task-notification>

        This is the delegate result you were waiting for. Relay what matters to the user in your own \
        voice — do not repeat this block verbatim or mention its internal fields.
        """
    }

    /// Drives the child run to completion under a wall-clock budget, cancelling the child if the
    /// parent turn is cancelled or the budget expires.
    private func runLocalAgentChild(
        childConversationID: UUID,
        prompt: String,
        timeoutSeconds: TimeInterval
    ) async -> LocalAgentRunOutcome {
        guard let childRun = localAgentChildRunPort else {
            return .failed("in-process delegate runtime is not configured")
        }
        let completion = await withTaskCancellationHandler {
            await withTaskGroup(of: LocalAgentRunOutcome?.self) { group in
                group.addTask {
                    do {
                        try await childRun(childConversationID, prompt)
                        return nil
                    } catch is CancellationError {
                        return LocalAgentRunOutcome.cancelled
                    } catch {
                        return LocalAgentRunOutcome.failed("\(error)")
                    }
                }
                group.addTask {
                    let nanoseconds = UInt64(max(1, timeoutSeconds * 1000)) * 1_000_000
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return LocalAgentRunOutcome.cancelled
                    }
                    return LocalAgentRunOutcome.timedOut(timeoutSeconds)
                }
                let first: LocalAgentRunOutcome?
                if let produced = await group.next() {
                    first = produced
                } else {
                    first = LocalAgentRunOutcome.failed("delegate run produced no outcome")
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelChildRunForSubAgent(childConversationID: childConversationID)
            }
        }

        switch completion {
        case .some(let terminal):
            await cancelChildRunForSubAgent(childConversationID: childConversationID)
            return terminal
        case .none:
            guard let text = await lastAssistantText(childConversationID: childConversationID) else {
                return .failed("delegate produced no assistant reply")
            }
            return .completed(text)
        }
    }

    private func lastAssistantText(childConversationID: UUID) async -> String? {
        guard let conversation = await deps.persistenceDomain.modelConversation(id: childConversationID) else {
            return nil
        }
        return conversation.messages.last(where: { $0.role == .assistant })?.content
    }

    private func resolveLocalAgentModel(_ modelRef: String) async -> Model? {
        guard let reference = ModelReference.parse(modelRef),
              let ranked = deps.rankedRegistryEntriesProvider else {
            return nil
        }
        return await ranked(reference).first?.toModel()
    }

    /// Terminal lifecycle transition. Routing through `upsertSubAgentLifecycleEntry` is what
    /// releases the run-lane slot acquired during spawn.
    private func finishLocalAgentLifecycle(
        lifecycleID: String,
        parentConversationID: UUID,
        childConversationID: UUID?,
        delegateToolName: String?,
        toolCallID: String?,
        outcome: LocalAgentRunOutcome
    ) async {
        let entry = SubAgentLifecycleEntryPayload(
            lifecycleID: lifecycleID,
            parentConversationID: parentConversationID,
            childConversationID: childConversationID,
            delegateToolName: delegateToolName,
            phase: Self.lifecyclePhase(for: outcome),
            defaultTrustLevel: SubAgentTrustLevel.system.rawValue,
            permissionPolicy: SubAgentPermissionPolicy.askParent.rawValue,
            approvalRoute: .parent,
            toolCallID: toolCallID,
            completionSource: outcome.completionText,
            error: Self.lifecycleError(for: outcome)
        )
        await upsertSubAgentLifecycleEntry(parentConversationID: parentConversationID, entry: entry)
        await publishSubAgentLifecycleIfConfigured(parentConversationID: parentConversationID)
    }

    static func pendingHandleContent(displayName: String, handleID: String) -> String {
        """
        Delegate '\(displayName)' is running in the background (handle: \(handleID)).
        Its result arrives as a separate message when it finishes. Do not sleep, poll, or check on \
        its progress, and do not guess at what it will return — continue with other work or reply \
        to the user in the meantime.
        """
    }

    static func toolResultContent(for outcome: LocalAgentRunOutcome, displayName: String) -> String {
        switch outcome {
        case .completed(let text):
            let bounded = SubAgentDelegateResultBounds.boundContent(text)
            let trimmed = trimmingTrailingWhitespace(bounded)
            return trimmed.isEmpty ? "Delegate '\(displayName)' completed without a report." : trimmed
        case .failed(let message):
            return "Delegate '\(displayName)' failed: \(message)"
        case .timedOut(let seconds):
            // Name the setting: a bare "300s timeout" is indistinguishable from the tool-call
            // timeout, which fails for an entirely different reason and has a different fix.
            return "Delegate '\(displayName)' exceeded its runTimeoutSeconds budget of \(Int(seconds))s and was cancelled."
        case .cancelled:
            return "Delegate '\(displayName)' was cancelled."
        }
    }

    /// Short 3-5 word label supplied by the model; keeps the full brief out of the child's topic.
    static func delegateTaskLabel(from arguments: JSON) -> String? {
        guard case .object(let object) = arguments,
              case .string(let label)? = object[Self.taskLabelArgumentName] else {
            return nil
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Per-call delivery-mode override. `nil` leaves the agent's configured default in force.
    static func delegateRunInBackground(from arguments: JSON) -> Bool? {
        guard case .object(let object) = arguments else { return nil }
        switch object[Self.runInBackgroundArgumentName] {
        case .boolean(let value):
            return value
        case .string(let raw):
            // Some providers stringify booleans on the wire.
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    static var instructionsArgumentName: String { InProcessLocalAgentToolProvider.instructionsParameterName }
    static var runInBackgroundArgumentName: String { InProcessLocalAgentToolProvider.runInBackgroundParameterName }
    static var taskLabelArgumentName: String { InProcessLocalAgentToolProvider.descriptionParameterName }
}

extension SubAgentSpawnService {
    /// Terminal phase derived from runtime signals, never from the child's self-reported text.
    static func lifecyclePhase(for outcome: LocalAgentRunOutcome) -> SubAgentLifecyclePhase {
        switch outcome {
        case .completed: .done
        case .failed, .timedOut, .cancelled: .failed
        }
    }

    static func lifecycleError(for outcome: LocalAgentRunOutcome) -> String? {
        switch outcome {
        case .completed: nil
        case .failed(let message): message
        case .timedOut(let seconds): "delegate run exceeded runTimeoutSeconds budget of \(Int(seconds))s"
        case .cancelled: "delegate run cancelled"
        }
    }
}

extension SubAgentSpawnService.LocalAgentRunOutcome {
    var completionText: String? {
        guard case .completed(let text) = self else { return nil }
        return text
    }

    var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }
}

extension SubAgentSpawnService {
    /// Tightest of the mode-profile and per-agent caps; `nil` when neither is set so the execution
    /// coordinator's transport cap and fail-closed fallback still apply.
    static func effectiveMaxDepth(modeProfileMaxDepth: Int?, definitionMaxDepth: Int?) -> Int? {
        switch (modeProfileMaxDepth, definitionMaxDepth) {
        case (nil, nil): nil
        case (let profile?, nil): profile
        case (nil, let definition?): definition
        case (let profile?, let definition?): min(profile, definition)
        }
    }

    /// Anthropic rejects tool-result content blocks with trailing whitespace.
    static func trimmingTrailingWhitespace(_ raw: String) -> String {
        var result = raw
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }
}
