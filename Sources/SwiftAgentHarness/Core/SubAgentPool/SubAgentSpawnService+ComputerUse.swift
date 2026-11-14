import EasyJSON
import Foundation
import SwiftAgentKit
import Synchronization

extension SubAgentSpawnService {
    /// Runs one delegated computer-use task: lease the target (one grant dialog), run the specialist in an
    /// isolated child whose only tools are the computer-use family, and hand back a structured result. The
    /// parent never sees the child's transcript, screenshots, or screen text.
    func invokeComputerUseSpecialist(
        call: ToolCallRequest,
        conversationID: UUID,
        parentConversation: ModelConversation,
        toolEntry: ToolRegistryEntry,
        groupIndex: ToolPolicyGroupIndex = .empty,
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
        let grantNotes = task.grantNotes(reviewedBy: configuration.registry.reviewer)
        let reply: (ComputerUseResult) -> ToolDispatchOutcome = { result in
            var result = result
            if !grantNotes.isEmpty { result.grantNotes = grantNotes }
            return .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: call.id, content: result.parentContent))
        }

        let userConversationID = await subAgentRootConversationID(for: conversationID)
        let modePolicy: @Sendable () async -> ComputerUseModePolicy = { [weak self] in
            await self?.computerUseModePolicy(from: conversationID, root: userConversationID, toolEntry: toolEntry, groupIndex: groupIndex)
                ?? ComputerUseModePolicy()
        }
        let startPolicy = await modePolicy()
        if startPolicy.denied {
            return reply(.notStarted(.blocked, reason: "the mode of a conversation this task was delegated from denies computer use", task: task))
        }

        let definition = ComputerUseDelegateToolProvider.specialistDefinition(configuration.specialist)
        var model = parentConversation.model
        if let modelRef = definition.modelRef {
            guard let resolved = await resolveLocalAgentModel(modelRef) else {
                return reply(.notStarted(.blocked, reason: "the computer-use model '\(modelRef)' did not resolve", task: task))
            }
            model = resolved
        }
        guard model.capabilities.contains(.tools) else {
            return reply(.notStarted(.blocked, reason: "model \(model.modelName) cannot call tools; bind a computer-use model", task: task))
        }
        let seesImages = model.capabilities.contains(.vision)
        let perception: ComputerUsePerceptionModels
        do {
            perception = try await computerUsePerception(configuration.specialist, seesImages: seesImages, conversationID: conversationID)
        } catch {
            return reply(.notStarted(.blocked, reason: error.reason, task: task))
        }
        guard seesImages || perception.describer != nil else {
            return reply(.notStarted(
                .blocked,
                reason: "model \(model.modelName) cannot see images and no model that can is registered for vision-describe; "
                    + "bind a computer-use model",
                task: task
            ))
        }
        let profile = await deps.registryEntryProvider?(model.id)?.profile(for: .generate)
        if configuration.requiresZeroRetention, seesImages, Self.retainsAtVendor(model: model, profile: profile) {
            return reply(.notStarted(
                .blocked,
                reason: "model \(model.modelName) keeps every screenshot on the vendor's side (vendor-stored), and this host "
                    + "requires zero retention; bind a computer-use model whose vendor doesn't store the conversation",
                task: task
            ))
        }

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
                    initiator: origin.initiator,
                    userPresent: origin.userPresent
                ),
                purpose: task.goal,
                answer: configuration.answerGrants
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
            await grant.target.release(grant.lease, reason: .cancelled)
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
                successCriteria: task.successCriteria,
                returnSchema: task.returnSchema
            ),
            model: profile
        )
        sessionConfiguration.classifier.reviewer = configuration.registry.reviewer
        sessionConfiguration.conversationID = childID
        sessionConfiguration.showsScreenshots = seesImages
        sessionConfiguration.describer = perception.describer
        sessionConfiguration.grounder = perception.grounder
        sessionConfiguration.clampImageLimit(
            toLongEdge: deps.conversationTransformConfiguration.toolResultFormatting.maxInlineImagePixelDimension
        )
        sessionConfiguration.nativeDialect = !seesImages ? nil : await Self.nativeDialect(
            model: model,
            profile: profile,
            imageLimit: sessionConfiguration.imageLimit,
            layout: try? await grant.target.describe(grant.lease),
            manifest: grant.target.manifest
        )
        let cardHarness = await deps.persistenceDomain.harnessSessionPersistence
        let cardInstallation = deps.computerUse
        cardInstallation.readBlob = { try cardHarness.getBlob(blobId: $0) }
        let cardEndsAt = grant.lease.endsAt
        // Approval cards cite their crops by ref; the session's reference holds them like its screenshots.
        sessionConfiguration.storeApprovalImage = { data in
            guard let stored = try? cardHarness.putBlob(
                data: data, durability: .ephemeral, originalName: "computer-use-approval.png", mimeType: "image/png",
                trust: "unknown-party", ttlSeconds: 3_600, lane: .outbound
            ) else { return nil }
            let until = await cardInstallation.toolImageExpiry(conversationID: childID) ?? cardInstallation.sessionImageExpiry(endsAt: cardEndsAt)
            for expiry in await cardInstallation.blobs.hold([stored.id], childConversationID: childID, until: until) {
                _ = try? cardHarness.setBlobExpiry(blobId: expiry.blobID, expiresAt: expiry.expiresAt)
            }
            return stored.id
        }
        // Gemini's functions take the 0–999 grid whatever the catalog says; the mode is frozen with the session.
        if sessionConfiguration.nativeDialect?.toolset.vendor == .gemini {
            sessionConfiguration.coordinateMode = .normalized1000
        }
        // Approvals, questions, and activity go to the user's conversation: the root of the delegation tree, which
        // is the parent unless the parent is itself a delegate. A nested specialist's requests name its path. Waiting
        // on the user pauses the child's idle clock, and every action the session reports is a sign of life.
        let userConversation = userConversationID == conversationID
            ? parentConversation
            : await deps.persistenceDomain.modelConversation(id: userConversationID) ?? parentConversation
        if userConversationID != conversationID {
            let path = await subAgentPathSegments(for: childID)
            sessionConfiguration.delegatePath = path.isEmpty ? ComputerUseDelegateToolProvider.toolName : path.joined(separator: "/")
        }
        sessionConfiguration.confirmsInteract = startPolicy.confirmsInteract
        sessionConfiguration.modePolicy = modePolicy
        let targetLabel = grant.target.manifest.label
        let servesLiveView = grant.target.manifest.observerAccess != .none
        let sharedScreen = grant.target.manifest.humanPresence == .shared
        let liveness = DelegateLiveness()
        var approvals = configuration.approvals
        if approvals == nil {
            approvals = await orchestratorRuntime.approvalDelivery(for: userConversation)
        }
        approvals = approvals.map { ComputerUseLivenessApprovals(base: $0, liveness: liveness) }
        let oversight: (any ComputerUseOversight)? = (configuration.oversight ?? deps.computerUse.coordinator.map {
            ComputerUseConversationOversight(
                coordinator: $0,
                conversationID: userConversationID,
                lifecycleID: lifecycleID,
                targetLabel: targetLabel,
                delegatePath: sessionConfiguration.delegatePath
            )
        }).map { ComputerUseLivenessOversight(base: $0, liveness: liveness) }
        let publish = deps.computerUse.publish
        let observer = configuration.activityObserver
        let takenOver = Mutex(false)
        let activity: @Sendable (ComputerUseActivity) async -> Void = { update in
            let on = update.status == .takenOver
            let changed = takenOver.withLock { current in
                defer { current = on }
                return current != on
            }
            if changed { on ? liveness.pause() : liveness.resume() } else { liveness.touch() }
            guard publish != nil || observer != nil else { return }
            let payload = Self.activityPayload(update, target: targetLabel, lifecycleID: lifecycleID, liveView: servesLiveView, sharedScreen: sharedScreen)
            await publish?(userConversationID, .computerUseActivity(payload))
            await observer?(payload)
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
            ComputerUseSessionEntry(session: session, parentConversationID: userConversationID, lifecycleID: lifecycleID, targetLabel: targetLabel),
            for: childID
        )
        let installation = deps.computerUse
        let harnessForImages = await deps.persistenceDomain.harnessSessionPersistence
        await session.observeEndsAt { endsAt in
            let until = installation.sessionImageExpiry(endsAt: endsAt)
            for expiry in await installation.blobs.moveSession(childConversationID: childID, until: until) {
                _ = try? harnessForImages.setBlobExpiry(blobId: expiry.blobID, expiresAt: expiry.expiresAt)
            }
        }
        await session.announceStart()
        var outcome = await runLocalAgentChild(
            childConversationID: childID,
            prompt: task.brief,
            deadline: { [grace = configuration.specialist.cleanupGraceSeconds] in await session.childRunDeadline(grace: grace) },
            idleTimeoutSeconds: configuration.specialist.idleTimeoutSeconds,
            liveness: liveness
        )
        // A rejected finish ends the loop like any halt signal, so the specialist's one more try is a short rerun, while the session is still live.
        if case .completed = outcome, let problems = await session.finishRejection {
            let retry = await runLocalAgentChild(
                childConversationID: childID,
                prompt: ComputerUseResultBuilder.refinishPrompt(problems, schema: task.returnSchema),
                timeoutSeconds: configuration.specialist.cleanupGraceSeconds,
                idleTimeoutSeconds: configuration.specialist.idleTimeoutSeconds
            )
            if case .completed = retry { outcome = retry }
        }
        await deps.computerUse.sessions.remove(for: childID)
        switch outcome {
        case .completed: await session.end()
        case .idleTimedOut: await session.end(.idleTimeout)
        case .timedOut: await session.end(.timeBudget)
        case .failed, .cancelled: await session.end(.cancelled)
        }

        var result = await Self.specialistResult(
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
        // Kept downloads become attachments of the delegating conversation; the rest of a managed browser's go.
        let persistence = deps.persistenceDomain
        let listed = await session.finalizeDownloads(attachmentLimit: SessionPersistenceConfiguration.blobMaxBytes) { download, data in
            let mimeType = SessionBlobMIME.sniff(data: data, hint: nil)
            guard let stored = try? cardHarness.putBlob(
                data: data, durability: .durable, originalName: download.name, mimeType: mimeType,
                trust: AttachmentProvenancePolicy.defaultTrustRaw(for: .agent), ttlSeconds: nil, lane: .inbound
            ) else { return nil }
            do {
                try await persistence.appendAgentAttachment(
                    conversationID: conversationID, blobId: stored.id, name: download.name, mimeType: mimeType, byteSize: Int64(data.count)
                )
            } catch {
                return nil
            }
            return stored.id
        }
        if !listed.isEmpty { result.downloads = listed }
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

    /// Whether the model's computer-use calls would go to a vendor API that stores the conversation: its feature
    /// says so, and its native toolset (if any) is one the model's codec speaks, so the stored API is used.
    static func retainsAtVendor(model: Model, profile: ContractProfile?) -> Bool {
        guard let support = profile.flatMap(ComputerUseModelSupport.init(profile:)), support.dataRetention == .vendorStored else {
            return false
        }
        guard let toolset = ComputerUseNativeToolset(version: support.version) else { return true }
        return toolset.modelProtocol == model.modelProtocol
    }

    /// The vendor's native toolset when the model speaks that vendor's API and its catalog version names one.
    /// Anthropic's older single-tool versions also declare the screen size, which is what a display screenshot comes
    /// out as; Gemini's environment follows the target.
    static func nativeDialect(
        model: Model,
        profile: ContractProfile?,
        imageLimit: ObservationImageLimit?,
        layout: TargetLayout?,
        manifest: DisplayTargetManifest? = nil
    ) -> ComputerUseNativeDialect? {
        let support = profile.flatMap(ComputerUseModelSupport.init(profile:))
        guard let toolset = ComputerUseNativeToolset(version: support?.version),
              model.modelProtocol == toolset.modelProtocol
        else { return nil }
        let api = support?.api
        switch toolset.vendor {
        case .anthropic: break
        case .openAI: return ComputerUseNativeDialect(toolset: toolset, api: api)
        case .gemini: return ComputerUseNativeDialect(toolset: toolset, environment: manifest.map(GeminiComputerEnvironment.init(manifest:)) ?? .browser, api: api)
        }
        guard !toolset.isToolset else { return ComputerUseNativeDialect(toolset: toolset, api: api) }
        guard let display = layout?.displays.first(where: \.isPrimary) ?? layout?.displays.first else {
            return ComputerUseNativeDialect(toolset: toolset, api: api)
        }
        let size = ObservationImageLimit.pixelSize(
            for: display.frame,
            nativeScale: display.scaleFactor,
            maxLongEdge: imageLimit?.longEdgePx,
            maxPixels: imageLimit?.maxPixels
        )
        return ComputerUseNativeDialect(toolset: toolset, displayWidthPx: size.width, displayHeightPx: size.height, api: api)
    }

    static func activityPayload(
        _ activity: ComputerUseActivity, target: String, lifecycleID: String, liveView: Bool, sharedScreen: Bool = false
    ) -> ComputerUseSurfaceIntentPayload {
        ComputerUseSurfaceIntentPayload(
            target: target,
            lifecycleID: lifecycleID,
            status: activity.status,
            step: activity.step,
            maxSteps: activity.maxSteps,
            extensions: activity.extensions,
            app: activity.app,
            action: activity.action?.rawValue,
            terminalReason: activity.terminalReason?.rawValue,
            liveView: liveView,
            sharedScreen: sharedScreen,
            notice: activity.notice
        )
    }

    static func specialistResult(
        task: ComputerUseTask,
        session: ComputerUseSession,
        outcome: LocalAgentRunOutcome,
        actionsLogRef: String?
    ) async -> ComputerUseResult {
        let child: ComputerUseChildOutcome
        switch outcome {
        case .completed:
            child = .completed
        case .failed(let message): child = .failed(message)
        case .timedOut: child = .timedOut
        case .idleTimedOut: child = .idleTimedOut
        case .cancelled: child = .cancelled
        }
        var actionsLog = await session.auditSummary
        if let actionsLogRef { actionsLog += " (full log: \(actionsLogRef))" }
        return ComputerUseResultBuilder.build(
            task: task,
            verifications: await session.verifications,
            terminal: await session.terminalReason,
            terminalDetail: await session.terminalDetail,
            budget: ComputerUseResult.Budget(
                stepsUsed: await session.stepCount,
                stepsGranted: await session.budgets.steps,
                extensions: await session.extensions,
                lastProgressStep: await session.progress.lastProgressStep
            ),
            child: child,
            unresolvedHandoff: await session.unresolvedHandoff,
            unresolvedQuestion: await session.unresolvedQuestion,
            headlessDenials: await session.headlessDenials.map(\.canonical),
            missingGrants: await session.missingGrants,
            finalText: await session.finishedResult,
            finished: await session.hasFinished,
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
        case .targetUnavailable(let reason):
            return .notStarted(.needsUser, reason: reason, task: task)
        }
    }

    /// Stores the replay (full action log plus observation thumbnails) and resets the run's image references: the
    /// session's and the replay's run for the release TTL, and an audit mark placed while the run was live adds one
    /// for the audit retention. Returns the replay document's ref.
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
        let ledger = deps.computerUse.blobs
        let auditMarked = await ledger.takeAuditMark(parent: parentConversationID, lifecycleID: lifecycleID)
        let expiresAt = retention.expiry(releasedAt: releasedAt, auditMarked: auditMarked)
        let normalExpiry = retention.expiry(releasedAt: releasedAt, auditMarked: false)
        let screenshots = await ledger.takeHeld(childConversationID: childConversationID)
        var blobIDs = screenshots
        let access = ComputerUseBlobAccess(
            load: { try harness.getBlob(blobId: $0) },
            setExpiry: { _ = try harness.setBlobExpiry(blobId: $0, expiresAt: $1) }
        )
        var expiries = await ledger.reference(screenshots, by: .session(childConversationID), until: normalExpiry)
        func finish() async {
            let run = (parent: parentConversationID, lifecycleID: lifecycleID)
            expiries += await ledger.reference(blobIDs, by: .replay(parent: run.parent, lifecycleID: run.lifecycleID), until: normalExpiry)
            if auditMarked {
                expiries += await ledger.reference(blobIDs, by: .audit(parent: run.parent, lifecycleID: run.lifecycleID), until: expiresAt)
            }
            var latest: [String: Date] = [:]
            for expiry in expiries { latest[expiry.blobID] = expiry.expiresAt }
            for (blobID, date) in latest { try? access.setExpiry(blobID, date) }
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
        ), !(replay.records.isEmpty && replay.thumbnails.isEmpty) else {
            await finish()
            return nil
        }
        replay.screenshotBlobIDs = blobIDs
        guard let data = try? JSONEncoder.computerUseReplay.encode(replay),
              let documentBlobID = try? put(data, "computer-use-replay-\(session.id.uuidString).json", "application/json")
        else {
            await finish()
            return nil
        }
        blobIDs += replay.thumbnails.map(\.blobID) + [documentBlobID]
        await finish()
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

    /// The computer-use policy of every mode over a session: the delegating conversation's and each one above it, up
    /// to the user's root. Modes restrict computer use down the whole delegation chain, so the strictest applies.
    /// Conversations are read fresh, so a mode changed since the session started is what counts.
    func computerUseModePolicy(
        from conversationID: UUID,
        root: UUID,
        toolEntry: ToolRegistryEntry,
        groupIndex: ToolPolicyGroupIndex
    ) async -> ComputerUseModePolicy {
        var chain: [ModelConversation] = []
        var visited: Set<UUID> = []
        var cursor: UUID? = conversationID
        while let id = cursor, visited.insert(id).inserted, let conversation = await deps.persistenceDomain.modelConversation(id: id) {
            chain.append(conversation)
            cursor = conversation.parentConversationID
        }
        if !visited.contains(root), let conversation = await deps.persistenceDomain.modelConversation(id: root) {
            chain.append(conversation)
        }
        var policy = ComputerUseModePolicy()
        for conversation in chain {
            let profile = await resolvedModeProfile(for: conversation)
            policy.confirmsInteract = policy.confirmsInteract || profile.subAgents.computerUse.confirmsInteract
            let denyRules = ToolPolicyRulesCache.parseList(profile.tools.deny)
            if ToolPolicyNameMatcher.denylistBlocks(rules: denyRules, toolName: toolEntry.name, entry: toolEntry, groupIndex: groupIndex) {
                policy.denied = true
            }
        }
        return policy
    }
}
