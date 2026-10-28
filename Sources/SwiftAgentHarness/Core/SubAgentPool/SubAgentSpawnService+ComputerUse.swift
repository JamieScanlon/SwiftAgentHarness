import EasyJSON
import Foundation
import SwiftAgentKit

extension SubAgentSpawnService {
    /// Runs one delegated computer-use task: lease the target (one grant dialog), run the specialist in an
    /// isolated child whose only tools are the computer-use family, and hand back a structured result. The
    /// parent never sees the child's transcript, screenshots, or screen text.
    func invokeComputerUseSpecialist(
        call: ToolCallRequest,
        conversationID: UUID,
        parentConversation: ModelConversation,
        toolEntry: ToolRegistryEntry,
        origin: ComputerUseRunOrigin
    ) async -> ToolDispatchOutcome {
        guard let configuration = deps.computerUse.configuration else {
            return .denied(AgentLoopToolDispatch.toolResultMessage(
                toolCallId: call.id,
                content: "Tool dispatch denied: computer use is not configured."
            ))
        }
        let task: ComputerUseTask
        do {
            task = try ComputerUseTask(arguments: call.arguments, defaults: configuration.defaults)
        } catch {
            return .denied(AgentLoopToolDispatch.toolResultMessage(
                toolCallId: call.id,
                content: "Tool dispatch denied: \(error.message)."
            ))
        }
        let reply: (ComputerUseResult) -> ToolDispatchOutcome = { result in
            .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: call.id, content: result.jsonString))
        }

        let definition = ComputerUseDelegateToolProvider.specialistDefinition(configuration.specialist)
        var model = parentConversation.model
        if let modelRef = definition.modelRef {
            guard let resolved = await resolveLocalAgentModel(modelRef) else {
                return reply(.notStarted(.blocked, reason: "the computer-use model '\(modelRef)' did not resolve", task: task))
            }
            model = resolved
        }
        guard model.capabilities.contains(.vision), model.capabilities.contains(.tools) else {
            return reply(.notStarted(
                .blocked,
                reason: "model \(model.modelName) cannot both see images and call tools; bind a computer-use model",
                task: task
            ))
        }
        let profile = await deps.registryEntryProvider?(model.id)?.profile(for: .generate)

        let lifecycleID = call.id ?? "model-\(conversationID.uuidString)-\(UUID().uuidString)"
        let grant: ComputerUseLeaseGrant
        do {
            grant = try await configuration.registry.lease(
                LeaseRequest(
                    target: task.target,
                    conversationID: conversationID,
                    agentID: "computer-use:\(lifecycleID)",
                    grants: task.grants,
                    budgets: task.budgets,
                    operatorInitiated: origin.operatorInitiated,
                    userPresent: origin.userPresent
                ),
                purpose: task.goal,
                approve: configuration.approveGrants
            )
        } catch {
            return reply(Self.leaseDenialResult(error, task: task))
        }

        let label = Self.delegateTaskLabel(from: call.arguments) ?? ComputerUseDelegateToolProvider.displayName
        let childID: UUID
        do {
            childID = try await spawnLocalAgentChild(
                conversationID: conversationID,
                parentConversation: parentConversation,
                toolEntry: toolEntry,
                definition: definition,
                instructions: task.brief,
                label: label,
                runInBackground: false,
                lifecycleID: lifecycleID,
                modelOverride: definition.modelRef == nil ? nil : model
            )
        } catch {
            await grant.target.release(grant.lease, reason: .error)
            await finishLocalAgentLifecycle(
                lifecycleID: lifecycleID,
                parentConversationID: conversationID,
                childConversationID: nil,
                delegateToolName: toolEntry.name,
                toolCallID: call.id,
                outcome: .failed("\(error)")
            )
            return reply(.notStarted(.failed, reason: "the specialist could not start: \(error)", task: task))
        }

        var sessionConfiguration = ComputerUseSessionConfiguration(
            task: ComputerUseTaskContext(
                userRequest: [task.goal],
                constraints: task.constraints,
                successCriteria: task.successCriteria
            ),
            model: profile
        )
        sessionConfiguration.conversationID = childID
        sessionConfiguration.clampImageLimit(
            toLongEdge: deps.conversationTransformConfiguration.toolResultFormatting.maxInlineImagePixelDimension
        )
        sessionConfiguration.nativeDialect = await Self.nativeDialect(
            model: model,
            profile: profile,
            imageLimit: sessionConfiguration.imageLimit,
            layout: try? await grant.target.describe(grant.lease)
        )
        // Approvals, questions, and activity go to the user's conversation, not the specialist's child.
        let targetLabel = grant.target.manifest.label
        var approvals = configuration.approvals
        if approvals == nil {
            approvals = await orchestratorRuntime.approvalDelivery(for: parentConversation)
        }
        let oversight: (any ComputerUseOversight)? = configuration.oversight ?? deps.computerUse.coordinator.map {
            ComputerUseConversationOversight(coordinator: $0, conversationID: conversationID, lifecycleID: lifecycleID, targetLabel: targetLabel)
        }
        var activity: (@Sendable (ComputerUseActivity) async -> Void)?
        let publish = deps.computerUse.publish
        let observer = configuration.activityObserver
        if publish != nil || observer != nil {
            activity = { update in
                let payload = Self.activityPayload(update, target: targetLabel, lifecycleID: lifecycleID)
                await publish?(conversationID, .computerUseActivity(payload))
                await observer?(payload)
            }
        }
        let session = ComputerUseSession(
            target: grant.target,
            lease: grant.lease,
            configuration: sessionConfiguration,
            approvals: approvals,
            intentChecker: configuration.intentChecker,
            oversight: oversight,
            activity: activity
        )
        await deps.computerUse.sessions.register(
            ComputerUseSessionEntry(session: session, parentConversationID: conversationID, lifecycleID: lifecycleID, targetLabel: targetLabel),
            for: childID
        )
        await session.announceStart()
        let outcome = await runLocalAgentChild(
            childConversationID: childID,
            prompt: task.brief,
            timeoutSeconds: min(definition.runTimeoutSeconds, task.budgets.maxDuration.timeInterval)
        )
        await deps.computerUse.sessions.remove(for: childID)
        await session.end()

        let result = await Self.specialistResult(
            task: task,
            session: session,
            outcome: outcome,
            actionsLogRef: await releaseRunBlobs(
                session: session,
                childConversationID: childID,
                parentConversationID: conversationID,
                lifecycleID: lifecycleID,
                targetLabel: targetLabel
            )
        )
        await finishLocalAgentLifecycle(
            lifecycleID: lifecycleID,
            parentConversationID: conversationID,
            childConversationID: childID,
            delegateToolName: toolEntry.name,
            toolCallID: call.id,
            outcome: outcome
        )
        return reply(result)
    }

    /// Anthropic's native toolset when the model speaks Anthropic's API and its catalog version names one. The
    /// older single-tool versions also declare the screen size, which is what a display screenshot comes out as.
    static func nativeDialect(
        model: Model,
        profile: ContractProfile?,
        imageLimit: ObservationImageLimit?,
        layout: TargetLayout?
    ) -> ComputerUseNativeDialect? {
        guard model.modelProtocol == .anthropic,
              let toolset = ComputerUseNativeToolset(version: profile.flatMap(ComputerUseModelSupport.init(profile:))?.version)
        else { return nil }
        guard !toolset.isToolset else { return ComputerUseNativeDialect(toolset: toolset) }
        guard let display = layout?.displays.first(where: \.isPrimary) ?? layout?.displays.first else {
            return ComputerUseNativeDialect(toolset: toolset)
        }
        let size = ObservationImageLimit.pixelSize(
            for: display.frame,
            nativeScale: display.scaleFactor,
            maxLongEdge: imageLimit?.longEdgePx,
            maxPixels: imageLimit?.maxPixels
        )
        return ComputerUseNativeDialect(toolset: toolset, displayWidthPx: size.width, displayHeightPx: size.height)
    }

    static func activityPayload(_ activity: ComputerUseActivity, target: String, lifecycleID: String) -> ComputerUseSurfaceIntentPayload {
        ComputerUseSurfaceIntentPayload(
            target: target,
            lifecycleID: lifecycleID,
            status: activity.status,
            step: activity.step,
            maxSteps: activity.maxSteps,
            app: activity.app,
            action: activity.action?.rawValue,
            terminalReason: activity.terminalReason?.rawValue
        )
    }

    static func specialistResult(
        task: ComputerUseTask,
        session: ComputerUseSession,
        outcome: LocalAgentRunOutcome,
        actionsLogRef: String?
    ) async -> ComputerUseResult {
        let child: ComputerUseChildOutcome
        var finalText: String?
        switch outcome {
        case .completed(let text):
            child = .completed
            finalText = text
        case .failed(let message): child = .failed(message)
        case .timedOut: child = .timedOut
        case .cancelled: child = .cancelled
        }
        var actionsLog = await session.auditSummary
        if let actionsLogRef { actionsLog += " (full log: \(actionsLogRef))" }
        return ComputerUseResultBuilder.build(
            task: task,
            verifications: await session.verifications,
            terminal: await session.terminalReason,
            child: child,
            unresolvedHandoff: await session.unresolvedHandoff,
            headlessDenials: await session.headlessDenials.map(\.canonical),
            finalText: finalText,
            actionsLog: actionsLog
        )
    }

    static func leaseDenialResult(_ error: any Error, task: ComputerUseTask) -> ComputerUseResult {
        guard let denial = error as? ComputerUseLeaseDenial else {
            return .notStarted(.failed, reason: "\(error)", task: task)
        }
        switch denial {
        case .grantsDeclined:
            return .notStarted(.blocked, reason: "the user declined the requested app and domain grants", task: task)
        case .hostTargetRequiresPresentOperator:
            var result = ComputerUseResult.notStarted(
                .needsUser,
                reason: "the host desktop needs an operator-started run with the user present",
                task: task
            )
            result.handoff = ComputerUseResult.Handoff(
                reason: ComputerUseHandoffReason.consequential.rawValue,
                prompt: "Run this task while you are present, or configure an isolated display target."
            )
            return result
        case .targetBusy(let holder):
            return .notStarted(.blocked, reason: "the display target is in use by \(holder)", task: task)
        case .permissionsMissing(let permissions):
            return .notStarted(.blocked, reason: "missing platform permissions: \(permissions.map(\.rawValue).joined(separator: ", "))", task: task)
        case .unknownTarget(let id):
            return .notStarted(.blocked, reason: "no display target named \(id)", task: task)
        case .foregroundUnsupported:
            return .notStarted(.blocked, reason: "the target does not support foreground delivery", task: task)
        case .driverFailure(let message):
            return .notStarted(.failed, reason: message, task: task)
        }
    }

    /// Stores the replay (full action log plus observation thumbnails) and starts the retention clock on every
    /// image the run held: the release TTL, or the audit retention for a run the user marked. Returns the replay
    /// document's ref.
    private func releaseRunBlobs(
        session: ComputerUseSession,
        childConversationID: UUID,
        parentConversationID: UUID,
        lifecycleID: String,
        targetLabel: String
    ) async -> String? {
        let harness = await deps.persistenceDomain.harnessSessionPersistence
        let retention = deps.computerUse.retention
        let releasedAt = Date()
        let auditMarked = await deps.computerUse.blobs.takeAuditMark(parent: parentConversationID, lifecycleID: lifecycleID)
        let expiresAt = retention.expiry(releasedAt: releasedAt, auditMarked: auditMarked)
        var blobIDs = await deps.computerUse.blobs.takeHeld(childConversationID: childConversationID)
        let access = ComputerUseBlobAccess(
            load: { try harness.getBlob(blobId: $0) },
            setExpiry: { _ = try harness.setBlobExpiry(blobId: $0, expiresAt: $1) }
        )
        defer {
            for blobID in blobIDs { try? access.setExpiry(blobID, expiresAt) }
            _ = try? harness.sweepExpiredBlobs()
        }

        let ttlSeconds = max(1, Int(retention.afterRelease.timeInterval.rounded(.up)))
        let put: (Data, String, String) throws -> String = { data, name, mimeType in
            try harness.putBlob(
                data: data,
                durability: .ephemeral,
                originalName: name,
                mimeType: mimeType,
                trust: "unknown-party",
                ttlSeconds: ttlSeconds,
                lane: .outbound
            ).id
        }
        guard var replay = try? await ComputerUseReplay(
            session: session,
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID,
            targetLabel: targetLabel,
            endedAt: releasedAt,
            storeThumbnail: { try put($0, "computer-use-thumbnail.png", "image/png") }
        ), !(replay.records.isEmpty && replay.thumbnails.isEmpty) else { return nil }
        replay.screenshotBlobIDs = blobIDs
        guard let data = try? JSONEncoder.computerUseReplay.encode(replay),
              let documentBlobID = try? put(data, "computer-use-replay-\(session.id.uuidString).json", "application/json")
        else { return nil }
        blobIDs += replay.thumbnails.map(\.blobID) + [documentBlobID]
        await deps.computerUse.replays.record(ComputerUseReplayIndexEntry(
            replay: replay,
            documentBlobID: documentBlobID,
            blobIDs: blobIDs,
            releasedAt: releasedAt,
            auditMarked: auditMarked,
            expiresAt: expiresAt,
            access: access
        ))
        return SessionBlobImageRef.path(for: documentBlobID)
    }
}
