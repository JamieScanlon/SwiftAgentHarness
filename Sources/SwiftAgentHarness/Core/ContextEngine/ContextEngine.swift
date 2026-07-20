import Foundation
import SwiftAgentKit

public struct ContextMemoryInjectionSnapshotSpec: Sendable {
    let conversationID: UUID
    let phase: ContextTransformInvocationPhase
    let memoryStoreVersion: Int
    let memoryStoreNamespaceKey: String?
    let injectedMemoryEntryIDs: [UUID]
    let selectedSelectionKeys: [String]
    let projectedSelectionKeys: [String]
    let selectionContextMessageIDs: [UUID]
    let selectorConfigFingerprint: String

    init(
        conversationID: UUID,
        phase: ContextTransformInvocationPhase,
        memoryStoreVersion: Int,
        memoryStoreNamespaceKey: String?,
        injectedMemoryEntryIDs: [UUID],
        selectedSelectionKeys: [String] = [],
        projectedSelectionKeys: [String] = [],
        selectionContextMessageIDs: [UUID] = [],
        selectorConfigFingerprint: String = ""
    ) {
        self.conversationID = conversationID
        self.phase = phase
        self.memoryStoreVersion = memoryStoreVersion
        self.memoryStoreNamespaceKey = memoryStoreNamespaceKey
        self.injectedMemoryEntryIDs = injectedMemoryEntryIDs
        self.selectedSelectionKeys = selectedSelectionKeys
        self.projectedSelectionKeys = projectedSelectionKeys
        self.selectionContextMessageIDs = selectionContextMessageIDs
        self.selectorConfigFingerprint = selectorConfigFingerprint
    }
}

/// Optional policy input for pre-compaction memory flush behavior.
public struct ContextEnginePreCompactionMemoryFlushPolicyInput: Sendable {
    public let enabled: Bool
    public let maxFlushedMemoryEntries: Int
    /// Soft headroom below the hard proactive threshold (diagnostics / soft-path gating).
    public let softThresholdTokens: Int

    public init(
        enabled: Bool = false,
        maxFlushedMemoryEntries: Int = 64,
        softThresholdTokens: Int = 8_000
    ) {
        self.enabled = enabled
        self.maxFlushedMemoryEntries = max(1, maxFlushedMemoryEntries)
        self.softThresholdTokens = max(0, softThresholdTokens)
    }
}

/// Persistable pre-compaction memory flush snapshot spec.
public struct ContextPreCompactionMemoryFlushSpec: Sendable {
    let conversationID: UUID
    let phase: ContextTransformInvocationPhase
    let memoryStoreVersion: Int
    let memoryStoreNamespaceKey: String?
    let flushedMemoryEntryIDs: [UUID]
}

/// Projection policy input for trust-aware context filtering and attachment shaping.
public struct ContextEngineProjectionPolicyInput: Sendable {
    let requestInputTrustRaw: String?
    let safeDefaultTrustClass: TrustPolicyClass
    let downgradeLowTrustContext: Bool
    let deterministicAttachmentHygiene: ContextCompactionAttachmentDocumentHygienePolicy?
    let attachmentCatalog: [ConversationAttachmentDescriptor]
    let modelSupportsVision: Bool?
    let systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput?
    let attachmentProjectionPolicy: ContextEngineAttachmentProjectionPolicyInput?
    let attachmentBlobReader: AttachmentBlobReading?
    let useSessionTreeProjection: Bool
    let sessionTranscriptEntries: [SessionTranscriptEntry]?
    let contextPruningPolicy: ContextPruningPolicy?
    let priorAttachmentProjection: ContextEngineAttachmentProjectionArtifact?
    let pendingCacheBreakEvents: Set<CacheBreakEventReason>

    init(
        requestInputTrustRaw: String? = nil,
        safeDefaultTrustClass: TrustPolicyClass = .lowTrust,
        downgradeLowTrustContext: Bool = false,
        deterministicAttachmentHygiene: ContextCompactionAttachmentDocumentHygienePolicy? = nil,
        attachmentCatalog: [ConversationAttachmentDescriptor] = [],
        modelSupportsVision: Bool? = nil,
        systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput? = nil,
        attachmentProjectionPolicy: ContextEngineAttachmentProjectionPolicyInput? = nil,
        attachmentBlobReader: AttachmentBlobReading? = nil,
        useSessionTreeProjection: Bool = false,
        sessionTranscriptEntries: [SessionTranscriptEntry]? = nil,
        contextPruningPolicy: ContextPruningPolicy? = nil,
        priorAttachmentProjection: ContextEngineAttachmentProjectionArtifact? = nil,
        pendingCacheBreakEvents: Set<CacheBreakEventReason> = []
    ) {
        self.requestInputTrustRaw = requestInputTrustRaw
        self.safeDefaultTrustClass = safeDefaultTrustClass
        self.downgradeLowTrustContext = downgradeLowTrustContext
        self.deterministicAttachmentHygiene = deterministicAttachmentHygiene
        self.attachmentCatalog = attachmentCatalog
        self.modelSupportsVision = modelSupportsVision
        self.systemPromptAssemblyPolicy = systemPromptAssemblyPolicy
        self.attachmentProjectionPolicy = attachmentProjectionPolicy
        self.attachmentBlobReader = attachmentBlobReader
        self.useSessionTreeProjection = useSessionTreeProjection
        self.sessionTranscriptEntries = sessionTranscriptEntries
        self.contextPruningPolicy = contextPruningPolicy
        self.priorAttachmentProjection = priorAttachmentProjection
        self.pendingCacheBreakEvents = pendingCacheBreakEvents
    }
}

/// Inputs required to project system prompt metadata/fingerprint under CE ownership.
public struct ContextEngineSystemPromptAssemblyPolicyInput: Sendable {
    let resolvedModeProfile: ResolvedModeProfile
    let strictAgentHarnessPrompts: Bool
    let includeAgentSkills: Bool
    let includeDateTime: Bool
    let toolPolicySignature: String
    let routingPolicyTools: [String]
    let routingPolicySkills: [String]
    let providerContribution: SystemPromptContribution?

    init(
        resolvedModeProfile: ResolvedModeProfile,
        strictAgentHarnessPrompts: Bool,
        includeAgentSkills: Bool,
        includeDateTime: Bool,
        toolPolicySignature: String,
        routingPolicyTools: [String],
        routingPolicySkills: [String],
        providerContribution: SystemPromptContribution? = nil
    ) {
        self.resolvedModeProfile = resolvedModeProfile
        self.strictAgentHarnessPrompts = strictAgentHarnessPrompts
        self.includeAgentSkills = includeAgentSkills
        self.includeDateTime = includeDateTime
        self.toolPolicySignature = toolPolicySignature
        self.routingPolicyTools = routingPolicyTools
        self.routingPolicySkills = routingPolicySkills
        self.providerContribution = providerContribution
    }
}

/// Recency and working-set policy for attachment projection rungs.
public struct ContextEngineAttachmentRecencyPolicyInput: Sendable, Equatable {
    let enabled: Bool
    let hotAccessTurns: Int
    let demoteInlineAfterTurns: Int
    let demoteDigestAfterTurns: Int
    let hysteresisTurnMargin: Int
    let maxInlineImages: Int
    let promoteHotSetOnCompaction: Int

    public init(
        enabled: Bool = true,
        hotAccessTurns: Int = 3,
        demoteInlineAfterTurns: Int = 8,
        demoteDigestAfterTurns: Int = 20,
        hysteresisTurnMargin: Int = 2,
        maxInlineImages: Int = 2,
        promoteHotSetOnCompaction: Int = 5
    ) {
        self.enabled = enabled
        self.hotAccessTurns = max(0, hotAccessTurns)
        self.demoteInlineAfterTurns = max(0, demoteInlineAfterTurns)
        self.demoteDigestAfterTurns = max(0, demoteDigestAfterTurns)
        self.hysteresisTurnMargin = max(0, hysteresisTurnMargin)
        self.maxInlineImages = max(0, maxInlineImages)
        self.promoteHotSetOnCompaction = max(0, promoteHotSetOnCompaction)
    }

    public static let `default` = ContextEngineAttachmentRecencyPolicyInput()
}

/// Inputs for deterministic attachment inlining/summarization projection decisions.
public struct ContextEngineAttachmentProjectionPolicyInput: Sendable {
    let enabled: Bool
    let inlineByteLimit: Int64
    let summarizeByteLimit: Int64
    let recencyPolicy: ContextEngineAttachmentRecencyPolicyInput

    init(
        enabled: Bool = true,
        inlineByteLimit: Int64 = 256_000,
        summarizeByteLimit: Int64 = 2_000_000,
        recencyPolicy: ContextEngineAttachmentRecencyPolicyInput = .default
    ) {
        self.enabled = enabled
        self.inlineByteLimit = inlineByteLimit
        self.summarizeByteLimit = summarizeByteLimit
        self.recencyPolicy = recencyPolicy
    }
}

/// Artifact projected by CE for system prompt assembly + checkpoint parity.
public struct ContextEngineSystemPromptAssemblyArtifact: Sendable {
    let metadata: [String: String]
    let fingerprint: String
    let tier1MemorySectionContent: String?
    let workspaceSectionContent: String?
    let memorySnapshotGeneration: Int?
    let assembledSystemPromptText: String?
    let assembledPromptDigest: String?
    let replaySpec: SystemPromptAssemblyReplaySpec?
    let replaySpecDigest: String?
    let sectionProvenance: [String: String]?
    let frozenSkillsIndexXML: String?

    init(
        metadata: [String: String],
        fingerprint: String,
        tier1MemorySectionContent: String?,
        workspaceSectionContent: String?,
        memorySnapshotGeneration: Int?,
        assembledSystemPromptText: String?,
        assembledPromptDigest: String?,
        replaySpec: SystemPromptAssemblyReplaySpec? = nil,
        replaySpecDigest: String? = nil,
        sectionProvenance: [String: String]? = nil,
        frozenSkillsIndexXML: String? = nil
    ) {
        self.metadata = metadata
        self.fingerprint = fingerprint
        self.tier1MemorySectionContent = tier1MemorySectionContent
        self.workspaceSectionContent = workspaceSectionContent
        self.memorySnapshotGeneration = memorySnapshotGeneration
        self.assembledSystemPromptText = assembledSystemPromptText
        self.assembledPromptDigest = assembledPromptDigest
        self.replaySpec = replaySpec
        self.replaySpecDigest = replaySpecDigest
        self.sectionProvenance = sectionProvenance
        self.frozenSkillsIndexXML = frozenSkillsIndexXML
    }
}

/// Attachment projection artifact emitted by CE for provider/transformer consumption.
public struct ContextEngineAttachmentProjectionArtifact: Sendable {
    let projectionFingerprint: String
    let decisions: [ConversationAttachmentProjectionDecision]
    let targetDecisions: [ConversationAttachmentProjectionDecision]?
    let materializedBlocks: [AttachmentMaterializedBlock]
    let accessWatermarkTurnIndex: Int?
    let newDigestCheckpoints: [AttachmentDigestCheckpointWire]

    init(
        projectionFingerprint: String,
        decisions: [ConversationAttachmentProjectionDecision],
        targetDecisions: [ConversationAttachmentProjectionDecision]? = nil,
        materializedBlocks: [AttachmentMaterializedBlock] = [],
        accessWatermarkTurnIndex: Int? = nil,
        newDigestCheckpoints: [AttachmentDigestCheckpointWire] = []
    ) {
        self.projectionFingerprint = projectionFingerprint
        self.decisions = decisions
        self.targetDecisions = targetDecisions
        self.materializedBlocks = materializedBlocks
        self.accessWatermarkTurnIndex = accessWatermarkTurnIndex
        self.newDigestCheckpoints = newDigestCheckpoints
    }
}

/// Persistable checkpoint trigger emitted by CE projection lifecycle.
public struct ContextSystemPromptAssemblyCheckpointPersistenceSpec: Sendable {
    let conversationID: UUID
    let fingerprint: String
    let assembledPromptDigest: String?
    let replaySpecDigest: String?
    let assembledPrompt: String?
    let sectionProvenanceJSON: String?

    init(
        conversationID: UUID,
        fingerprint: String,
        assembledPromptDigest: String? = nil,
        replaySpecDigest: String? = nil,
        assembledPrompt: String? = nil,
        sectionProvenanceJSON: String? = nil
    ) {
        self.conversationID = conversationID
        self.fingerprint = fingerprint
        self.assembledPromptDigest = assembledPromptDigest
        self.replaySpecDigest = replaySpecDigest
        self.assembledPrompt = assembledPrompt
        self.sectionProvenanceJSON = sectionProvenanceJSON
    }
}

/// Persistable checkpoint trigger for CE attachment projection decisions.
public struct ContextAttachmentProjectionCheckpointPersistenceSpec: Sendable {
    let conversationID: UUID
    let projectionFingerprint: String
    let decisions: [ConversationAttachmentProjectionDecision]
    let targetDecisions: [ConversationAttachmentProjectionDecision]?
    let materializedBlocks: [AttachmentMaterializedBlock]
    let accessWatermarkTurnIndex: Int?

    init(
        conversationID: UUID,
        projectionFingerprint: String,
        decisions: [ConversationAttachmentProjectionDecision],
        targetDecisions: [ConversationAttachmentProjectionDecision]? = nil,
        materializedBlocks: [AttachmentMaterializedBlock] = [],
        accessWatermarkTurnIndex: Int? = nil
    ) {
        self.conversationID = conversationID
        self.projectionFingerprint = projectionFingerprint
        self.decisions = decisions
        self.targetDecisions = targetDecisions
        self.materializedBlocks = materializedBlocks
        self.accessWatermarkTurnIndex = accessWatermarkTurnIndex
    }
}

/// Persistable checkpoint trigger for CE attachment digest cache entries.
public struct ContextAttachmentDigestCheckpointPersistenceSpec: Sendable {
    let conversationID: UUID
    let checkpoints: [AttachmentDigestCheckpointWire]

    init(conversationID: UUID, checkpoints: [AttachmentDigestCheckpointWire]) {
        self.conversationID = conversationID
        self.checkpoints = checkpoints
    }
}

/// Deterministic CE projection artifact consumed by manager/provider layers.
public struct ContextEngineProjectionArtifact: Sendable {
    let resolvedRequestTrustClass: TrustPolicyClass?
    let systemPromptAssembly: ContextEngineSystemPromptAssemblyArtifact?
    let attachmentProjection: ContextEngineAttachmentProjectionArtifact?
}

/// Lifecycle bootstrap request for one conversation/session runtime.
public struct ContextEngineBootstrapRequest: Sendable {
    let conversationID: UUID
    let runID: UUID?
}

/// Lifecycle bootstrap result.
public struct ContextEngineBootstrapResult: Sendable {
    let initialized: Bool
}

/// Lifecycle ingest request for a single message.
public struct ContextEngineIngestRequest: Sendable {
    let conversationID: UUID
    let message: Message
}

/// Lifecycle ingest request for message batches.
public struct ContextEngineIngestBatchRequest: Sendable {
    let conversationID: UUID
    let messages: [Message]
}

/// Lifecycle ingest result.
public struct ContextEngineIngestResult: Sendable {
    let ingestedCount: Int
}

/// Assemble-stage request for model-facing context projection.
public struct ContextEngineAssembleRequest: Sendable {
    let messages: [Message]
    let conversation: ModelConversation
    let phase: ContextTransformInvocationPhase
    let gatingOverride: ContextCompactionGatingOptions?
    let compactionCustomInstructionsOverride: String?
    let enableContextTransform: Bool
    let compactionConfig: ContextCompactionConfiguration
    let transformMetadata: ConversationTransformMetadata
    let lastContextLimitTokens: Int?
    let lastPromptTokens: Int?
    let events: [CachedConversationEvent]
    let eventLogFrontier: Int
    let lastModelRequestAtByConversationID: [UUID: Date]
    let lastCompactionLLMDateByConversationID: [UUID: Date]
    let persistCompactionCheckpoint: Bool
    let allowProactiveCompactionTriggers: Bool
    let compactionLockAlreadyHeldByCaller: Bool
    let derivedTailAtProjectionStart: Int?
    let projectionPolicy: ContextEngineProjectionPolicyInput?
    let preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput?
    let sessionMemoryNoteForCompaction: String?
    let preCompactionMemoryFlushSpec: ContextPreCompactionMemoryFlushSpec?
    let workspacePolicy: HarnessWorkspacePolicy

    init(
        messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        gatingOverride: ContextCompactionGatingOptions?,
        compactionCustomInstructionsOverride: String?,
        enableContextTransform: Bool,
        compactionConfig: ContextCompactionConfiguration,
        transformMetadata: ConversationTransformMetadata,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        events: [CachedConversationEvent],
        eventLogFrontier: Int,
        lastModelRequestAtByConversationID: [UUID: Date],
        lastCompactionLLMDateByConversationID: [UUID: Date],
        persistCompactionCheckpoint: Bool,
        allowProactiveCompactionTriggers: Bool,
        compactionLockAlreadyHeldByCaller: Bool,
        derivedTailAtProjectionStart: Int?,
        projectionPolicy: ContextEngineProjectionPolicyInput? = nil,
        preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput? = nil,
        sessionMemoryNoteForCompaction: String? = nil,
        preCompactionMemoryFlushSpec: ContextPreCompactionMemoryFlushSpec? = nil,
        workspacePolicy: HarnessWorkspacePolicy = .default
    ) {
        self.messages = messages
        self.conversation = conversation
        self.phase = phase
        self.gatingOverride = gatingOverride
        self.compactionCustomInstructionsOverride = compactionCustomInstructionsOverride
        self.enableContextTransform = enableContextTransform
        self.compactionConfig = compactionConfig
        self.transformMetadata = transformMetadata
        self.lastContextLimitTokens = lastContextLimitTokens
        self.lastPromptTokens = lastPromptTokens
        self.events = events
        self.eventLogFrontier = eventLogFrontier
        self.lastModelRequestAtByConversationID = lastModelRequestAtByConversationID
        self.lastCompactionLLMDateByConversationID = lastCompactionLLMDateByConversationID
        self.persistCompactionCheckpoint = persistCompactionCheckpoint
        self.allowProactiveCompactionTriggers = allowProactiveCompactionTriggers
        self.compactionLockAlreadyHeldByCaller = compactionLockAlreadyHeldByCaller
        self.derivedTailAtProjectionStart = derivedTailAtProjectionStart
        self.projectionPolicy = projectionPolicy
        self.preCompactionMemoryFlushPolicy = preCompactionMemoryFlushPolicy
        self.sessionMemoryNoteForCompaction = sessionMemoryNoteForCompaction
        self.preCompactionMemoryFlushSpec = preCompactionMemoryFlushSpec
        self.workspacePolicy = workspacePolicy
    }
}

/// Assemble-stage result for orchestrator inputs and optional checkpoint persistence spec.
public struct ContextEngineAssembleResult: Sendable {
    let messages: [Message]
    let transformOutput: ContextTransformOutput?
    let checkpointPersistence: ContextCompactionCheckpointPersistenceSpec?
    let memoryInjectionSnapshot: ContextMemoryInjectionSnapshotSpec?
    let transformFailed: Bool
    let passthroughReason: String?
    let projectionArtifact: ContextEngineProjectionArtifact?
    let systemPromptCheckpoint: ContextSystemPromptAssemblyCheckpointPersistenceSpec?
    let attachmentProjectionCheckpoint: ContextAttachmentProjectionCheckpointPersistenceSpec?
    let attachmentDigestCheckpoints: ContextAttachmentDigestCheckpointPersistenceSpec?
    let preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec?
    let compactionLowSavings: Bool
    let projectedMemorySelectionKeys: [String]
    let cacheExpiredHygieneWindow: Bool

    init(
        messages: [Message],
        transformOutput: ContextTransformOutput?,
        checkpointPersistence: ContextCompactionCheckpointPersistenceSpec?,
        memoryInjectionSnapshot: ContextMemoryInjectionSnapshotSpec?,
        transformFailed: Bool,
        passthroughReason: String?,
        projectionArtifact: ContextEngineProjectionArtifact? = nil,
        systemPromptCheckpoint: ContextSystemPromptAssemblyCheckpointPersistenceSpec? = nil,
        attachmentProjectionCheckpoint: ContextAttachmentProjectionCheckpointPersistenceSpec? = nil,
        attachmentDigestCheckpoints: ContextAttachmentDigestCheckpointPersistenceSpec? = nil,
        preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec? = nil,
        compactionLowSavings: Bool = false,
        projectedMemorySelectionKeys: [String] = [],
        cacheExpiredHygieneWindow: Bool = false
    ) {
        self.messages = messages
        self.transformOutput = transformOutput
        self.checkpointPersistence = checkpointPersistence
        self.memoryInjectionSnapshot = memoryInjectionSnapshot
        self.transformFailed = transformFailed
        self.passthroughReason = passthroughReason
        self.projectionArtifact = projectionArtifact
        self.systemPromptCheckpoint = systemPromptCheckpoint
        self.attachmentProjectionCheckpoint = attachmentProjectionCheckpoint
        self.attachmentDigestCheckpoints = attachmentDigestCheckpoints
        self.preCompactionMemoryFlush = preCompactionMemoryFlush
        self.compactionLowSavings = compactionLowSavings
        self.projectedMemorySelectionKeys = projectedMemorySelectionKeys
        self.cacheExpiredHygieneWindow = cacheExpiredHygieneWindow
    }
}

/// Request for projection-policy-derived context budget used by conversation state publishing.
public struct ContextEngineProjectedContextBudgetRequest: Sendable {
    let messages: [Message]
    let conversation: ModelConversation
    let compactionConfig: ContextCompactionConfiguration
    let lastContextLimitTokens: Int?
    let lastPromptTokens: Int?
    let projectionPolicy: ContextEngineProjectionPolicyInput?
}

/// Compact-stage request (manual/recovery/forced flows).
public struct ContextEngineCompactRequest: Sendable {
    let assemble: ContextEngineAssembleRequest
}

/// Compact-stage result mirrors assemble result.
public typealias ContextEngineCompactResult = ContextEngineAssembleResult

/// Post-turn lifecycle request.
public struct ContextEngineAfterTurnRequest: Sendable {
    let conversationID: UUID
    let runID: UUID?
    let terminalReason: ConversationRunTerminalReason?
    let anchorUserMessageID: UUID?
    let recentMessages: [Message]

    init(
        conversationID: UUID,
        runID: UUID?,
        terminalReason: ConversationRunTerminalReason?,
        anchorUserMessageID: UUID? = nil,
        recentMessages: [Message] = []
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.terminalReason = terminalReason
        self.anchorUserMessageID = anchorUserMessageID
        self.recentMessages = recentMessages
    }
}

/// Post-turn lifecycle result.
public struct ContextEngineAfterTurnResult: Sendable {
    let completed: Bool
}

/// Sub-agent pre-spawn lifecycle request.
public struct ContextEnginePrepareSubagentSpawnRequest: Sendable {
    let conversationID: UUID
    let runID: UUID?
    let candidateToolNames: [String]
    let permissionPolicyByToolName: [String: SubAgentPermissionPolicy]
    let trustLevelByToolName: [String: SubAgentTrustLevel]
    let preApprovedToolNames: Set<String>
    let compositionMode: SubagentPromptCompositionMode?
    let parentConversationID: UUID?
    let taskDescription: String?
    let spawnPrompt: String?
    let spawnUserSystemPrompt: String?

    init(
        conversationID: UUID,
        runID: UUID?,
        candidateToolNames: [String],
        permissionPolicyByToolName: [String: SubAgentPermissionPolicy],
        trustLevelByToolName: [String: SubAgentTrustLevel],
        preApprovedToolNames: Set<String>,
        compositionMode: SubagentPromptCompositionMode? = nil,
        parentConversationID: UUID? = nil,
        taskDescription: String? = nil,
        spawnPrompt: String? = nil,
        spawnUserSystemPrompt: String? = nil
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.candidateToolNames = candidateToolNames
        self.permissionPolicyByToolName = permissionPolicyByToolName
        self.trustLevelByToolName = trustLevelByToolName
        self.preApprovedToolNames = preApprovedToolNames
        self.compositionMode = compositionMode
        self.parentConversationID = parentConversationID
        self.taskDescription = taskDescription
        self.spawnPrompt = spawnPrompt
        self.spawnUserSystemPrompt = spawnUserSystemPrompt
    }
}

public struct ContextEngineSubagentPromptCompositionArtifact: Sendable, Equatable {
    let mode: SubagentPromptCompositionMode
    let inheritedAssembledPromptText: String?
    let inheritedAssembledPromptDigest: String?
    let inheritedReplaySpecDigest: String?
    let spawnSectionSuppressions: Set<SystemPromptSectionName>?
    let spawnTaskDirective: String?
}

/// Deterministic CE artifact produced during sub-agent spawn preparation.
public struct ContextEngineSubagentHandoffArtifact: Sendable, Equatable {
    let conversationID: UUID
    let runID: UUID?
    let policyFingerprint: String
    let approvedToolNames: [String]
    let elevatedToolNames: [String]
}

/// Persistable CE directive for checkpoint invalidation from sub-agent hook lifecycles.
public struct ContextEngineSubagentCheckpointInvalidationSpec: Sendable, Equatable {
    let conversationID: UUID
    let invalidatedKinds: [String]
}

/// Sub-agent pre-spawn lifecycle result.
public struct ContextEnginePrepareSubagentSpawnResult: Sendable {
    let approvedToolNames: [String]
    let handoffArtifact: ContextEngineSubagentHandoffArtifact?
    let checkpointInvalidation: ContextEngineSubagentCheckpointInvalidationSpec?
    let promptCompositionArtifact: ContextEngineSubagentPromptCompositionArtifact?

    init(
        approvedToolNames: [String],
        handoffArtifact: ContextEngineSubagentHandoffArtifact? = nil,
        checkpointInvalidation: ContextEngineSubagentCheckpointInvalidationSpec? = nil,
        promptCompositionArtifact: ContextEngineSubagentPromptCompositionArtifact? = nil
    ) {
        self.approvedToolNames = approvedToolNames
        self.handoffArtifact = handoffArtifact
        self.checkpointInvalidation = checkpointInvalidation
        self.promptCompositionArtifact = promptCompositionArtifact
    }
}

/// Sub-agent ended lifecycle request.
public struct ContextEngineSubagentEndedRequest: Sendable {
    let conversationID: UUID
    let runID: UUID?
    let toolName: String
    let permissionPolicy: SubAgentPermissionPolicy?
    let trustLevel: SubAgentTrustLevel?
}

/// Deterministic CE artifact produced after sub-agent tool completion.
public struct ContextEngineSubagentContinuationArtifact: Sendable, Equatable {
    let conversationID: UUID
    let runID: UUID?
    let toolName: String
    let policyFingerprint: String
}

/// Sub-agent ended lifecycle result.
public struct ContextEngineSubagentEndedResult: Sendable {
    let acknowledged: Bool
    let continuationArtifact: ContextEngineSubagentContinuationArtifact?
    let checkpointInvalidation: ContextEngineSubagentCheckpointInvalidationSpec?

    init(
        acknowledged: Bool,
        continuationArtifact: ContextEngineSubagentContinuationArtifact? = nil,
        checkpointInvalidation: ContextEngineSubagentCheckpointInvalidationSpec? = nil
    ) {
        self.acknowledged = acknowledged
        self.continuationArtifact = continuationArtifact
        self.checkpointInvalidation = checkpointInvalidation
    }
}

/// Internal turn assembly aliases — same shape as lifecycle assemble request/result.
typealias ContextTurnAssemblyRequest = ContextEngineAssembleRequest
typealias ContextTurnAssemblyResult = ContextEngineAssembleResult

/// Checkpoint persistence bundle produced after a successful compaction transform (initial phase).
public struct ContextCompactionCheckpointPersistenceSpec: Sendable {
    let conversationID: UUID
    let rawMiddleMessageIDs: [UUID]
    let compactedMiddleMessages: [Message]
    /// Raw middle messages at compaction time; used to fan out summarized synthetics for checkpoint reuse.
    let coveredRawMiddle: [Message]
    let kind: ContextCompactionCheckpointKind
    let config: ContextCompactionConfiguration
    let strategyRawValue: String?
    let cachePolicyFingerprint: String?
    /// Expected derived tail captured when projection started.
    let expectedDerivedSequence: Int?
    let firstKeptTailMessageID: UUID?
    let summaryBodyForTranscript: String?
    let promptTokensBeforeCompaction: Int?
}

/// Harness-aligned façade for **model** context projection (compaction + checkpoint reuse). Wire implementations
/// must stay free of Vapor.
public protocol ContextEngine: Sendable {
    func bootstrap(request: ContextEngineBootstrapRequest) async -> ContextEngineBootstrapResult
    func ingest(request: ContextEngineIngestRequest) async -> ContextEngineIngestResult
    func ingestBatch(request: ContextEngineIngestBatchRequest) async -> ContextEngineIngestResult
    func assemble(
        request: ContextEngineAssembleRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineAssembleResult
    func compact(
        request: ContextEngineCompactRequest,
        performTransform: @Sendable @escaping (ContextTransformInput) async throws -> ContextTransformOutput
    ) async -> ContextEngineCompactResult
    func afterTurn(request: ContextEngineAfterTurnRequest) async -> ContextEngineAfterTurnResult
    func prepareSubagentSpawn(
        request: ContextEnginePrepareSubagentSpawnRequest
    ) async -> ContextEnginePrepareSubagentSpawnResult
    func onSubagentEnded(
        request: ContextEngineSubagentEndedRequest
    ) async -> ContextEngineSubagentEndedResult
    func projectedContextBudget(
        request: ContextEngineProjectedContextBudgetRequest
    ) async -> ConversationContextBudget?
}

extension ContextEngine {
    func projectedContextBudget(
        request: ContextEngineProjectedContextBudgetRequest
    ) async -> ConversationContextBudget? {
        let _ = request
        return nil
    }
}
