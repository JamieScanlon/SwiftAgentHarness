//
//  Copies inherited journal rows when forking, remapping storage message ids and local event ids.

import Foundation

extension ConversationManager {
    struct BranchInheritedModeSnapshot: Sendable, Equatable {
        let interactionModeRaw: String
        let modeProfileID: String?
    }

    private func rawPrefixEventCeiling(
        events: [CachedConversationEvent],
        allowedMessageIDs: Set<UUID>
    ) -> Int? {
        var ceiling: Int?
        for event in events where event.kind == ConversationEventKind.messageAppended.rawValue {
            guard let payload = ConversationEventCodec.decode(MessageAppendedEventPayload.self, from: event.payloadJSON),
                  allowedMessageIDs.contains(payload.messageID) else { continue }
            ceiling = max(ceiling ?? event.eventID, event.eventID)
        }
        return ceiling
    }

    private func normalizeBranchModeSnapshot(
        rawMode: String,
        rawProfileID: String?
    ) -> BranchInheritedModeSnapshot {
        let mode = InteractionMode(rawValue: rawMode) ?? .chat
        let normalizedProfileID = (rawProfileID?.isEmpty == false) ? rawProfileID : mode.rawValue

        return BranchInheritedModeSnapshot(
            interactionModeRaw: mode.rawValue,
            modeProfileID: normalizedProfileID
        )
    }

    func resolveInheritedModeSnapshotForSplitAnchor(
        parentConversationID: UUID,
        anchorMessageID: UUID,
        fallbackInteractionModeRaw: String,
        fallbackModeProfileID: String?
    ) -> BranchInheritedModeSnapshot {
        guard let transcript = try? harnessSessionPersistence.readTranscriptEntries(
            conversationID: parentConversationID,
            request: .full
        ),
        let anchorSequence = try? harnessSessionPersistence.transcriptEntry(
            conversationID: parentConversationID,
            messageID: anchorMessageID
        ).sequence else {
            return normalizeBranchModeSnapshot(
                rawMode: fallbackInteractionModeRaw,
                rawProfileID: fallbackModeProfileID
            )
        }

        let decodePayload: (SessionTranscriptEntry) -> InteractionModeChangedEventPayload? = { entry in
            guard entry.type == .conversationJournal,
                  let envelope = try? SessionTranscriptJournalEnvelopeCodec.decode(entry.payloadJSON),
                  envelope.kind == ConversationEventKind.interactionModeChanged.rawValue else {
                return nil
            }
            return ConversationEventCodec.decode(InteractionModeChangedEventPayload.self, from: envelope.innerPayloadJSON)
        }
        if let payload = transcript
            .lazy
            .filter({ $0.sequence <= anchorSequence })
            .compactMap(decodePayload)
            .last {
            return normalizeBranchModeSnapshot(
                rawMode: payload.toMode,
                rawProfileID: payload.toProfileID
            )
        }
        if let payload = transcript.lazy.compactMap(decodePayload).first {
            return normalizeBranchModeSnapshot(
                rawMode: payload.fromMode,
                rawProfileID: payload.fromProfileID
            )
        }
        return normalizeBranchModeSnapshot(
            rawMode: fallbackInteractionModeRaw,
            rawProfileID: fallbackModeProfileID
        )
    }

    func resolveInheritedModeSnapshotForBranch(
        parentConversationID: UUID,
        messageStorageIdMap: [UUID: UUID]
    ) throws -> BranchInheritedModeSnapshot {
        let (parentEvents, _) = loadConversationEventsWithFrontier(conversationID: parentConversationID)
        let allowedMessageIDs = Set(messageStorageIdMap.keys)
        let prefixCeiling = rawPrefixEventCeiling(events: parentEvents, allowedMessageIDs: allowedMessageIDs)
        let modeEvents = parentEvents.filter { $0.kind == ConversationEventKind.interactionModeChanged.rawValue }
        let fallback = modelConversation(id: parentConversationID)

        let rawMode: String
        let rawProfileID: String?
        if let ceiling = prefixCeiling,
           let event = modeEvents.last(where: { $0.eventID <= ceiling }),
           let payload = ConversationEventCodec.decode(InteractionModeChangedEventPayload.self, from: event.payloadJSON) {
            rawMode = payload.toMode
            rawProfileID = payload.toProfileID
        } else if let firstMode = modeEvents.first,
                  let payload = ConversationEventCodec.decode(InteractionModeChangedEventPayload.self, from: firstMode.payloadJSON) {
            rawMode = payload.fromMode
            rawProfileID = payload.fromProfileID
        } else {
            rawMode = fallback?.interactionMode.rawValue ?? InteractionMode.chat.rawValue
            rawProfileID = fallback?.modeProfileID
        }

        return normalizeBranchModeSnapshot(
            rawMode: rawMode,
            rawProfileID: rawProfileID
        )
    }

    private func branchJournalEventsToInclude(
        parents: [CachedConversationEvent],
        messageStorageIdMap: [UUID: UUID],
        allowSystemPromptAssemblyCheckpoint: Bool
    ) -> [CachedConversationEvent] {
        let allowedMessageIDs = Set(messageStorageIdMap.keys)
        let prefixCeiling = rawPrefixEventCeiling(events: parents, allowedMessageIDs: allowedMessageIDs)
        var included: [CachedConversationEvent] = []
        for ev in parents {
            switch DerivedArtifactContractMatrix.branchInheritanceRule(forPersistedKind: ev.kind) {
            case .messageAppendedScoped:
                if let payload = ConversationEventCodec.decode(MessageAppendedEventPayload.self, from: ev.payloadJSON),
                   messageStorageIdMap[payload.messageID] != nil {
                    included.append(ev)
                }
            case .turnSummaryScoped:
                if BranchJournalCheckpointFilter.shouldCopyTurnSummaryEvent(ev, allowedMessageIDs: allowedMessageIDs) {
                    included.append(ev)
                }
            case .durableCheckpointScoped:
                if BranchJournalCheckpointFilter.shouldCopyCheckpointEvent(
                    ev,
                    allowedMessageIDs: allowedMessageIDs,
                    allowSystemPromptAssemblyCheckpoint: allowSystemPromptAssemblyCheckpoint
                ) {
                    included.append(ev)
                }
            case .rawPrefixScoped:
                if let prefixCeiling, ev.eventID <= prefixCeiling {
                    included.append(ev)
                }
            case .copyVerbatim:
                included.append(ev)
            case .omit:
                continue
            }
        }
        return included
    }

    private func appendRemappedBranchJournalEventsToHarnessTranscript(
        childConversationID: UUID,
        included: [CachedConversationEvent],
        messageStorageIdMap: [UUID: UUID]
    ) throws {
        guard !included.isEmpty else { return }
        var oldEventToNew: [Int: Int] = [:]
        for (idx, ev) in included.enumerated() {
            oldEventToNew[ev.eventID] = idx + 1
        }
        var rawSeq = 0
        var derivedSeq = 0
        for ev in included {
            guard let newEventNumericID = oldEventToNew[ev.eventID] else { continue }
            let payload = remapPayloadForBranch(
                event: ev,
                payloadJSON: ev.payloadJSON,
                messageStorageIdMap: messageStorageIdMap,
                oldEventToNew: oldEventToNew
            )
            let newBased = ev.basedOnEventID.flatMap { oldEventToNew[$0] }
            let newCoverStart = ev.coversStartEventID.flatMap { oldEventToNew[$0] }
            let newCoverEnd = ev.coversEndEventID.flatMap { oldEventToNew[$0] }
            let stream = ConversationJournalStream(persistedEventKind: ev.kind)
            switch stream {
            case .raw:
                rawSeq += 1
            case .derived:
                derivedSeq += 1
            }
            let seq = stream == .raw ? rawSeq : derivedSeq
            let env = SessionTranscriptJournalEnvelope(
                eventID: newEventNumericID,
                journalStreamRaw: stream.rawValue,
                streamSequence: seq,
                kind: ev.kind,
                basedOnEventID: newBased,
                coversStartEventID: newCoverStart,
                coversEndEventID: newCoverEnd,
                innerPayloadJSON: payload
            )
            let json = try SessionTranscriptJournalEnvelopeCodec.encode(env)
            let entryType: SessionTranscriptEntryType = stream == .raw ? .conversationJournal : .derivedJournal
            let entry = SessionTranscriptEntry(
                sequence: 0,
                entryId: .generate(),
                parentEntryId: nil,
                type: entryType,
                timestamp: ev.createdAt,
                payloadJSON: json
            )
            try appendJournalEntryToChildTranscript(childConversationID: childConversationID, entry: entry)
        }
        TranscriptJournalTailCache.invalidate(conversationID: childConversationID)
    }

    /// Copies inherited journal rows onto a harness child conversation (v2 transcript), remapping message and event ids.
    func copyInheritedJournalEventsForHarnessBranch(
        parentConversationID: UUID,
        childConversationID: UUID,
        messageStorageIdMap: [UUID: UUID],
        parentSystemPrompt: String,
        childSystemPrompt: String
    ) throws {
        guard !messageStorageIdMap.isEmpty else { return }
        let (parents, _) = loadConversationEventsWithFrontier(conversationID: parentConversationID)
        let included = branchJournalEventsToInclude(
            parents: parents,
            messageStorageIdMap: messageStorageIdMap,
            allowSystemPromptAssemblyCheckpoint: parentSystemPrompt == childSystemPrompt
        )
        try appendRemappedBranchJournalEventsToHarnessTranscript(
            childConversationID: childConversationID,
            included: included,
            messageStorageIdMap: messageStorageIdMap
        )
    }

    /// Duplicates parent conversation journal events onto `childConversationID` after prefix messages were cloned (`messageStorageIdMap`: parent storage id → child storage id).
    func copyInheritedJournalEventsForBranch(
        parentConversationID: UUID,
        childConversationID: UUID,
        messageStorageIdMap: [UUID: UUID]
    ) throws {
        let parentPrompt = try cachedSystemPrompt(conversationID: parentConversationID)
        let childPrompt = try cachedSystemPrompt(conversationID: childConversationID)
        try copyInheritedJournalEventsForHarnessBranch(
            parentConversationID: parentConversationID,
            childConversationID: childConversationID,
            messageStorageIdMap: messageStorageIdMap,
            parentSystemPrompt: parentPrompt,
            childSystemPrompt: childPrompt
        )
    }

    private func cachedSystemPrompt(conversationID: UUID) throws -> String {
        guard let row = modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        return row.systemPrompt
    }

    private func remapPayloadForBranch(
        event: CachedConversationEvent,
        payloadJSON: String,
        messageStorageIdMap: [UUID: UUID],
        oldEventToNew: [Int: Int]
    ) -> String {
        func remapMessageID(_ id: UUID) -> UUID {
            messageStorageIdMap[id] ?? id
        }
        func remapEventID(_ id: Int) -> Int {
            oldEventToNew[id] ?? id
        }

        switch event.kind {
        case ConversationEventKind.messageAppended.rawValue:
            guard let payload = ConversationEventCodec.decode(MessageAppendedEventPayload.self, from: payloadJSON) else {
                return payloadJSON
            }
            return ConversationEventCodec.encode(
                MessageAppendedEventPayload(messageID: remapMessageID(payload.messageID))
            )
        case ConversationEventKind.turnSummaryEvent.rawValue:
            guard let payload = ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: payloadJSON) else {
                return payloadJSON
            }
            return ConversationEventCodec.encode(
                SummaryCreatedEventPayload(
                    summaryMessageID: payload.summaryMessageID,
                    summaryContent: payload.summaryContent,
                    coveredMessageIDs: payload.coveredMessageIDs.map(remapMessageID),
                    firstCoveredMessageID: payload.firstCoveredMessageID.map(remapMessageID),
                    basedOnEventID: oldEventToNew[payload.basedOnEventID] ?? payload.basedOnEventID,
                    startEventID: oldEventToNew[payload.startEventID] ?? payload.startEventID,
                    endEventID: oldEventToNew[payload.endEventID] ?? payload.endEventID,
                    basedOnTailMessageID: payload.basedOnTailMessageID.map(remapMessageID),
                    succeeded: payload.succeeded,
                    createdAt: payload.createdAt
                )
            )
        case ConversationEventKind.contextCompactionCheckpoint.rawValue:
            guard let payload = ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: payloadJSON) else {
                return payloadJSON
            }
            let remappedSynth = payload.syntheticMessages.map { dto in
                ContextCompactionMessageDTO(
                    id: remapMessageID(dto.id),
                    role: dto.role,
                    content: dto.content,
                    toolCalls: dto.toolCalls,
                    toolCallId: dto.toolCallId
                )
            }
            return ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: payload.schemaVersion,
                    kind: payload.kind,
                    coveredMessageIDs: payload.coveredMessageIDs.map(remapMessageID),
                    syntheticMessages: remappedSynth,
                    configFingerprint: payload.configFingerprint,
                    basedOnEventID: remapEventID(payload.basedOnEventID),
                    basedOnTailMessageID: payload.basedOnTailMessageID.map(remapMessageID),
                    strategyRawValue: payload.strategyRawValue,
                    cachePolicyFingerprint: payload.cachePolicyFingerprint,
                    createdAt: payload.createdAt
                )
            )
        case ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue:
            guard var wire = ConversationEventCodec.decode(MemoryInjectionSnapshotCheckpointWire.self, from: payloadJSON) else {
                return payloadJSON
            }
            wire = MemoryInjectionSnapshotCheckpointWire(
                schemaVersion: wire.schemaVersion,
                basedOnEventID: remapEventID(wire.basedOnEventID),
                injectionFingerprint: wire.injectionFingerprint,
                snapshotJSON: wire.snapshotJSON,
                scopeMessageIDs: wire.scopeMessageIDs.map(remapMessageID),
                memoryStoreVersion: wire.memoryStoreVersion,
                memoryStoreNamespaceKey: wire.memoryStoreNamespaceKey,
                memoryEntryIDs: wire.memoryEntryIDs,
                createdAt: wire.createdAt
            )
            return ConversationEventCodec.encode(wire)
        case ConversationEventKind.toolResultTrimCheckpoint.rawValue:
            guard var wire = ConversationEventCodec.decode(ToolResultTrimCheckpointWire.self, from: payloadJSON) else {
                return payloadJSON
            }
            wire = ToolResultTrimCheckpointWire(
                schemaVersion: wire.schemaVersion,
                basedOnEventID: remapEventID(wire.basedOnEventID),
                coveredMessageIDs: wire.coveredMessageIDs.map(remapMessageID),
                trimmedToolCallIds: wire.trimmedToolCallIds,
                configFingerprint: wire.configFingerprint,
                createdAt: wire.createdAt
            )
            return ConversationEventCodec.encode(wire)
        case ConversationEventKind.attachmentProjectionCheckpoint.rawValue:
            guard var wire = ConversationEventCodec.decode(AttachmentProjectionCheckpointWire.self, from: payloadJSON) else {
                return payloadJSON
            }
            wire = AttachmentProjectionCheckpointWire(
                schemaVersion: wire.schemaVersion,
                basedOnEventID: remapEventID(wire.basedOnEventID),
                projectionFingerprint: wire.projectionFingerprint,
                decisions: wire.decisions,
                createdAt: wire.createdAt
            )
            return ConversationEventCodec.encode(wire)
        case ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue:
            guard var wire = ConversationEventCodec.decode(SystemPromptAssemblyCheckpointWire.self, from: payloadJSON) else {
                return payloadJSON
            }
            wire = SystemPromptAssemblyCheckpointWire(
                schemaVersion: wire.schemaVersion,
                basedOnEventID: remapEventID(wire.basedOnEventID),
                assemblyFingerprint: wire.assemblyFingerprint,
                assembledPromptDigest: wire.assembledPromptDigest,
                replaySpecDigest: wire.replaySpecDigest,
                assembledPrompt: wire.assembledPrompt,
                sectionProvenanceJSON: wire.sectionProvenanceJSON,
                createdAt: wire.createdAt
            )
            return ConversationEventCodec.encode(wire)
        case ConversationEventKind.compactionApplied.rawValue:
            guard let payload = ConversationEventCodec.decode(CompactionAppliedEventPayload.self, from: payloadJSON) else {
                return payloadJSON
            }
            return ConversationEventCodec.encode(
                CompactionAppliedEventPayload(
                    uptoEventID: oldEventToNew[payload.uptoEventID] ?? payload.uptoEventID,
                    snapshotID: payload.snapshotID,
                    createdAt: payload.createdAt
                )
            )
        case ConversationEventKind.turnFinalized.rawValue:
            guard let payload = ConversationEventCodec.decode(TurnFinalizedEventPayload.self, from: payloadJSON) else {
                return payloadJSON
            }
            return ConversationEventCodec.encode(
                TurnFinalizedEventPayload(
                    basedOnEventID: oldEventToNew[payload.basedOnEventID] ?? payload.basedOnEventID,
                    createdAt: payload.createdAt
                )
            )
        default:
            return payloadJSON
        }
    }

    func copyInheritedJournalTranscriptEntriesForBranch(
        parentConversationID: UUID,
        childConversationID: UUID,
        anchorMessageID: UUID
    ) throws {
        guard let sourceConv = modelConversation(id: parentConversationID) else { return }
        let ordered = sourceConv.messages.sorted { $0.timestamp < $1.timestamp }
        guard let anchorIndex = ordered.firstIndex(where: { $0.id == anchorMessageID }) else { return }
        var messageStorageIdMap: [UUID: UUID] = [:]
        for message in ordered[0...anchorIndex] where message.role != .system {
            messageStorageIdMap[message.id] = message.id
        }
        try copyInheritedJournalEventsForHarnessBranch(
            parentConversationID: parentConversationID,
            childConversationID: childConversationID,
            messageStorageIdMap: messageStorageIdMap,
            parentSystemPrompt: sourceConv.systemPrompt,
            childSystemPrompt: sourceConv.systemPrompt
        )
    }

    private func appendJournalEntryToChildTranscript(
        childConversationID: UUID,
        entry: SessionTranscriptEntry
    ) throws {
        let lock = try harnessSessionPersistence.acquireTranscriptWriteLock(
            conversationID: childConversationID,
            allowReentrant: false
        )
        defer { lock.unlock() }
        let seq = try harnessSessionPersistence.nextTranscriptSequence(conversationID: childConversationID)
        var next = entry
        next.sequence = seq
        try harnessSessionPersistence.appendMirroredTranscriptEntry(
            conversationID: childConversationID,
            entry: next
        )
    }
}
