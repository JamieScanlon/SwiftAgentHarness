import Foundation
import SwiftAgentKit

public struct ContextMemoryInjectionSnapshotSpec: Sendable {
    let conversationID: UUID
    let phase: ContextTransformInvocationPhase
    let memoryStoreVersion: Int
    let memoryStoreNamespaceKey: String?
    let injectedMemoryEntryIDs: [UUID]
}

/// Optional policy input for pre-compaction memory flush behavior.
public struct ContextEnginePreCompactionMemoryFlushPolicyInput: Sendable {
    let enabled: Bool
    let maxFlushedMemoryEntries: Int

    init(enabled: Bool = false, maxFlushedMemoryEntries: Int = 64) {
        self.enabled = enabled
        self.maxFlushedMemoryEntries = max(1, maxFlushedMemoryEntries)
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
    let useSessionTreeProjection: Bool
    let sessionTranscriptEntries: [SessionTranscriptEntry]?

    init(
        requestInputTrustRaw: String? = nil,
        safeDefaultTrustClass: TrustPolicyClass = .lowTrust,
        downgradeLowTrustContext: Bool = false,
        deterministicAttachmentHygiene: ContextCompactionAttachmentDocumentHygienePolicy? = nil,
        attachmentCatalog: [ConversationAttachmentDescriptor] = [],
        modelSupportsVision: Bool? = nil,
        systemPromptAssemblyPolicy: ContextEngineSystemPromptAssemblyPolicyInput? = nil,
        attachmentProjectionPolicy: ContextEngineAttachmentProjectionPolicyInput? = nil,
        useSessionTreeProjection: Bool = false,
        sessionTranscriptEntries: [SessionTranscriptEntry]? = nil
    ) {
        self.requestInputTrustRaw = requestInputTrustRaw
        self.safeDefaultTrustClass = safeDefaultTrustClass
        self.downgradeLowTrustContext = downgradeLowTrustContext
        self.deterministicAttachmentHygiene = deterministicAttachmentHygiene
        self.attachmentCatalog = attachmentCatalog
        self.modelSupportsVision = modelSupportsVision
        self.systemPromptAssemblyPolicy = systemPromptAssemblyPolicy
        self.attachmentProjectionPolicy = attachmentProjectionPolicy
        self.useSessionTreeProjection = useSessionTreeProjection
        self.sessionTranscriptEntries = sessionTranscriptEntries
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
}

/// Inputs for deterministic attachment inlining/summarization projection decisions.
public struct ContextEngineAttachmentProjectionPolicyInput: Sendable {
    let enabled: Bool
    let inlineByteLimit: Int64
    let summarizeByteLimit: Int64

    init(
        enabled: Bool = true,
        inlineByteLimit: Int64 = 256_000,
        summarizeByteLimit: Int64 = 2_000_000
    ) {
        self.enabled = enabled
        self.inlineByteLimit = inlineByteLimit
        self.summarizeByteLimit = summarizeByteLimit
    }
}

/// Artifact projected by CE for system prompt assembly + checkpoint parity.
public struct ContextEngineSystemPromptAssemblyArtifact: Sendable {
    let metadata: [String: String]
    let fingerprint: String
}

/// Attachment projection artifact emitted by CE for provider/transformer consumption.
public struct ContextEngineAttachmentProjectionArtifact: Sendable {
    let projectionFingerprint: String
    let decisions: [ConversationAttachmentProjectionDecision]
}

/// Persistable checkpoint trigger emitted by CE projection lifecycle.
public struct ContextSystemPromptAssemblyCheckpointPersistenceSpec: Sendable {
    let conversationID: UUID
    let fingerprint: String
}

/// Persistable checkpoint trigger for CE attachment projection decisions.
public struct ContextAttachmentProjectionCheckpointPersistenceSpec: Sendable {
    let conversationID: UUID
    let projectionFingerprint: String
    let decisions: [ConversationAttachmentProjectionDecision]
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
    let lastLLMDateByConversationID: [UUID: Date]
    let persistCompactionCheckpoint: Bool
    let allowProactiveCompactionTriggers: Bool
    let compactionLockAlreadyHeldByCaller: Bool
    let derivedTailAtProjectionStart: Int?
    let projectionPolicy: ContextEngineProjectionPolicyInput?
    let preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput?
    let sessionMemoryNoteForCompaction: String?
    let preCompactionMemoryFlushSpec: ContextPreCompactionMemoryFlushSpec?

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
        lastLLMDateByConversationID: [UUID: Date],
        persistCompactionCheckpoint: Bool,
        allowProactiveCompactionTriggers: Bool,
        compactionLockAlreadyHeldByCaller: Bool,
        derivedTailAtProjectionStart: Int?,
        projectionPolicy: ContextEngineProjectionPolicyInput? = nil,
        preCompactionMemoryFlushPolicy: ContextEnginePreCompactionMemoryFlushPolicyInput? = nil,
        sessionMemoryNoteForCompaction: String? = nil,
        preCompactionMemoryFlushSpec: ContextPreCompactionMemoryFlushSpec? = nil
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
        self.lastLLMDateByConversationID = lastLLMDateByConversationID
        self.persistCompactionCheckpoint = persistCompactionCheckpoint
        self.allowProactiveCompactionTriggers = allowProactiveCompactionTriggers
        self.compactionLockAlreadyHeldByCaller = compactionLockAlreadyHeldByCaller
        self.derivedTailAtProjectionStart = derivedTailAtProjectionStart
        self.projectionPolicy = projectionPolicy
        self.preCompactionMemoryFlushPolicy = preCompactionMemoryFlushPolicy
        self.sessionMemoryNoteForCompaction = sessionMemoryNoteForCompaction
        self.preCompactionMemoryFlushSpec = preCompactionMemoryFlushSpec
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
    let preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec?
    let compactionLowSavings: Bool

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
        preCompactionMemoryFlush: ContextPreCompactionMemoryFlushSpec? = nil,
        compactionLowSavings: Bool = false
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
        self.preCompactionMemoryFlush = preCompactionMemoryFlush
        self.compactionLowSavings = compactionLowSavings
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

    init(
        approvedToolNames: [String],
        handoffArtifact: ContextEngineSubagentHandoffArtifact? = nil,
        checkpointInvalidation: ContextEngineSubagentCheckpointInvalidationSpec? = nil
    ) {
        self.approvedToolNames = approvedToolNames
        self.handoffArtifact = handoffArtifact
        self.checkpointInvalidation = checkpointInvalidation
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
