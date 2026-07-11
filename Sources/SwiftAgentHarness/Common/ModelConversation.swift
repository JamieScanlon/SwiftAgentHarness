import Foundation
import Combine
import EasyJSON
import SwiftAgentKit

public enum ConversationReasoningEffort: String, Codable, Sendable, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
}

public enum ConversationTranscriptIntegrityState: String, Codable, Sendable {
    case ok
    case quarantined
}

public struct ConversationTranscriptIntegrity: Codable, Sendable, Equatable {
    public var state: ConversationTranscriptIntegrityState
    public var reason: String?

    public init(state: ConversationTranscriptIntegrityState, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}

public struct ModelConversation: Identifiable, Codable, Sendable {
    /// Conversation identifier (catalog + in-process registry).
    public var id: UUID
    /// Resolved model for this conversation.
    public var model: Model
    /// In-process transcript projection (hydrated from harness lineage).
    public var messages: [Message]
    /// Orchestrator turn groupings.
    public var turns: [ConversationTurn]
    /// Transient streaming/generation UI state (distinct from ``resourceRunStatus``).
    public var state: ModelState
    public var showError: Bool
    public var errorMessage: String
    /// Catalog creation timestamp.
    public var createdAt: Date
    /// Catalog last-update timestamp.
    public var updatedAt: Date
    /// Persisted user/system prompt override.
    public var systemPrompt: String
    public var topic: String?
    public var description: String?
    /// When false, the model was removed from Ollama/LMStudio; the conversation is viewable read-only but cannot be continued.
    public var isModelAvailable: Bool
    /// Transient agentic tool-loop phase (not persisted to SwiftData).
    public var agenticPhase: ConversationAgenticPhase
    /// Transient per-LLM-request phase, e.g. FIFO queue (not persisted to SwiftData).
    public var llmRequestPhase: ConversationLLMRequestPhase?
    /// Persisted: chat vs plan (plan authoring) vs agent (build execution).
    public var interactionMode: InteractionMode
    /// Persisted registry pointer for mode policy resolution. When nil, callers fall back to
    /// built-in ids derived from ``interactionMode``.
    public var modeProfileID: String?
    /// Optional conversation-level metadata payload.
    public var metadata: JSON?
    /// When set, this conversation was branched from another via split; UI shows lineage after ``splitThreadAfterMessageID``.
    public var splitFromConversationID: UUID?
    /// Message id in this conversation after which the split divider is shown (copied anchor user message).
    public var splitThreadAfterMessageID: UUID?

    // MARK: Harness resource shape (see ``ConversationResourceShape``)

    /// Resource lifecycle — distinct from ``ModelState`` / streaming generation state.
    public var lifecycle: ConversationLifecycleState
    /// Harness-style run status for the conversation resource.
    public var resourceRunStatus: ConversationResourceRunStatus
    /// Active agent/run identifier when ``resourceRunStatus`` is non-idle; persisted when orchestration supplies one.
    public var currentRunID: UUID?
    /// General parent conversation (branch / sub-agent tree); mirrors split lineage when populated.
    public var parentConversationID: UUID?
    /// Multi-tenant owner; nil in single-user deployments.
    public var ownerAccountID: UUID?
    /// User- or harness-appended instructions (system override remains ``systemPrompt``).
    public var extraInstructions: String?
    /// When true, the canonical system message replaces the entire assembled prompt (escape hatch).
    public var systemPromptFullOverride: Bool
    /// Optional persisted routing preferences (model hint + explicit tool policy).
    public var routingPrefs: ConversationRoutingPrefs?
    /// Last durable budget snapshot for this conversation.
    public var budgetSnapshot: ConversationBudgetSnapshot?
    /// Denormalized index of child conversations branched from this one.
    public var branchChildren: [ConversationBranchRef]
    /// Conversation-level attachment catalog (metadata); bytes live in resource storage.
    public var attachmentsCatalog: [ConversationAttachmentDescriptor]
    /// User-visible tags for list/filter (harness `metadata.tags`).
    public var tags: [String]
    /// Last activity timestamp for eviction / suspend stories.
    public var lastActiveAt: Date?
    /// Monotonic token for REST ``PATCH`` optimistic concurrency (control-plane mutations); mirrored from persistence.
    public var controlPlaneRevision: UInt64
    /// Harness catalog `source` when known (e.g. `cli`); nil → adapters may treat row as SwiftData projection only.
    public var harnessPersistenceSource: String?
    /// Harness catalog `trust_class` when known.
    public var harnessPersistenceTrustClass: String?
    /// Harness catalog `agent_id` override; nil → ``SessionPersistenceLayout/defaultAgentId`` in catalog adapters.
    public var harnessPersistenceAgentId: String?
    /// Harness catalog `cwd` when known (shell / session working directory).
    public var harnessPersistenceCwd: String?
    /// Persisted transcript integrity from harness catalog (`transcript_integrity`); nil means ok.
    public var transcriptIntegrity: ConversationTranscriptIntegrity?
    /// Catalog lineage axis — immutable after creation.
    public var lineageKind: ConversationLineageKind
    /// Catalog origin axis — immutable after creation.
    public var origin: ConversationOrigin

    @available(*, deprecated, message: "Use routingPrefs.modelOptions.thinkingConfig instead")
    public var thinkingEnabled: Bool {
        get {
            switch routingPrefs?.modelOptions?.thinkingConfig {
            case .disabled, .level(.off, _):
                return false
            case .none:
                return model.capabilities.hasReasoningCapability
            default:
                return true
            }
        }
        set {
            var prefs = routingPrefs ?? ConversationRoutingPrefs()
            var options = prefs.modelOptions ?? ConversationRoutingModelOptions()
            options.thinkingConfig = newValue ? .adaptive : .disabled
            prefs.modelOptions = options
            routingPrefs = prefs
        }
    }

    @available(*, deprecated, message: "Use routingPrefs.modelOptions.thinkingConfig instead")
    public var reasoningEffort: ConversationReasoningEffort? {
        get {
            guard case .level(let level, _) = routingPrefs?.modelOptions?.thinkingConfig else {
                if model.modelProtocol == .openAIAPI, model.capabilities.contains(.thinking) {
                    return .medium
                }
                return nil
            }
            switch level {
            case .off:
                return .some(.none)
            case .minimal:
                return .minimal
            case .low:
                return .low
            case .medium:
                return .medium
            case .high, .xhigh:
                return .high
            }
        }
        set {
            var prefs = routingPrefs ?? ConversationRoutingPrefs()
            var options = prefs.modelOptions ?? ConversationRoutingModelOptions()
            if let newValue {
                switch newValue {
                case .none:
                    options.thinkingConfig = .level(.off, budgetTokens: nil)
                case .minimal:
                    options.thinkingConfig = .level(.minimal, budgetTokens: nil)
                case .low:
                    options.thinkingConfig = .level(.low, budgetTokens: nil)
                case .medium:
                    options.thinkingConfig = .level(.medium, budgetTokens: nil)
                case .high:
                    options.thinkingConfig = .level(.high, budgetTokens: nil)
                }
            } else {
                options.thinkingConfig = nil
            }
            prefs.modelOptions = options
            routingPrefs = prefs
        }
    }

    public var modelName: String {
        model.modelName
    }
    public var firstMessageContent: String {
        guard let firstMessage = messages.first(where: { $0.role == .user }) else {
            return ""
        }
        return Self.truncateForSidebarTitle(firstMessage.content)
    }

    public var displayTitle: String {
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            return Self.truncateForSidebarTitle(topic)
        }
        if let userContent = messages.first(where: {
            $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content {
            return Self.truncateForSidebarTitle(userContent)
        }
        if let content = messages.first(where: {
            $0.role != .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content {
            return Self.truncateForSidebarTitle(content)
        }
        return ""
    }

    private static func truncateForSidebarTitle(_ text: String, prefixLength: Int = 30) -> String {
        if text.count <= prefixLength {
            return text
        }
        return "\(text.prefix(prefixLength))..."
    }
    public var messageCount: Int {
        messages.count
    }

    public init(id: UUID = UUID(),
                model: Model,
                messages: [Message] = [],
                turns: [ConversationTurn] = [],
                state: ModelState = .idle,
                showError: Bool = false,
                errorMessage: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                systemPrompt: String = "",
                topic: String? = nil,
                description: String? = nil,
                isModelAvailable: Bool = true,
                agenticPhase: ConversationAgenticPhase = .idle,
                llmRequestPhase: ConversationLLMRequestPhase? = nil,
                interactionMode: InteractionMode = .chat,
                modeProfileID: String? = nil,
                metadata: JSON? = nil,
                splitFromConversationID: UUID? = nil,
                splitThreadAfterMessageID: UUID? = nil,
                lifecycle: ConversationLifecycleState = .active,
                resourceRunStatus: ConversationResourceRunStatus = .idle,
                currentRunID: UUID? = nil,
                parentConversationID: UUID? = nil,
                ownerAccountID: UUID? = nil,
                extraInstructions: String? = nil,
                systemPromptFullOverride: Bool = false,
                routingPrefs: ConversationRoutingPrefs? = nil,
                budgetSnapshot: ConversationBudgetSnapshot? = nil,
                branchChildren: [ConversationBranchRef] = [],
                attachmentsCatalog: [ConversationAttachmentDescriptor] = [],
                tags: [String] = [],
                lastActiveAt: Date? = nil,
                controlPlaneRevision: UInt64 = 0,
                harnessPersistenceSource: String? = nil,
                harnessPersistenceTrustClass: String? = nil,
                harnessPersistenceAgentId: String? = nil,
                harnessPersistenceCwd: String? = nil,
                transcriptIntegrity: ConversationTranscriptIntegrity? = nil,
                lineageKind: ConversationLineageKind = .root,
                origin: ConversationOrigin = .user) {
        self.id = id
        self.model = model
        self.messages = messages
        self.turns = turns
        self.state = state
        self.showError = showError
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.systemPrompt = systemPrompt
        self.topic = topic
        self.description = description
        self.isModelAvailable = isModelAvailable
        self.agenticPhase = agenticPhase
        self.llmRequestPhase = llmRequestPhase
        self.interactionMode = interactionMode
        self.modeProfileID = modeProfileID
        self.metadata = metadata
        self.splitFromConversationID = splitFromConversationID
        self.splitThreadAfterMessageID = splitThreadAfterMessageID
        self.lifecycle = lifecycle
        self.resourceRunStatus = resourceRunStatus
        self.currentRunID = currentRunID
        self.parentConversationID = parentConversationID
        self.ownerAccountID = ownerAccountID
        self.extraInstructions = extraInstructions
        self.systemPromptFullOverride = systemPromptFullOverride
        self.routingPrefs = routingPrefs
        self.budgetSnapshot = budgetSnapshot
        self.branchChildren = branchChildren
        self.attachmentsCatalog = attachmentsCatalog
        self.tags = tags
        self.lastActiveAt = lastActiveAt
        self.controlPlaneRevision = controlPlaneRevision
        self.harnessPersistenceSource = harnessPersistenceSource
        self.harnessPersistenceTrustClass = harnessPersistenceTrustClass
        self.harnessPersistenceAgentId = harnessPersistenceAgentId
        self.harnessPersistenceCwd = harnessPersistenceCwd
        self.transcriptIntegrity = transcriptIntegrity
        self.lineageKind = lineageKind
        self.origin = origin
    }

    public func conversationScope() -> ConversationScope {
        ConversationScope(
            selfID: id,
            parentID: parentConversationID,
            rootID: ConversationScope.subAgentRootConversationID(from: metadata, selfID: id),
            lineageKind: lineageKind,
            origin: origin,
            depth: ConversationScope.subAgentDepth(from: metadata)
        )
    }

    @available(*, deprecated, message: "Use the primary initializer and set routingPrefs.modelOptions.thinkingConfig instead")
    public init(id: UUID = UUID(),
                model: Model,
                messages: [Message] = [],
                turns: [ConversationTurn] = [],
                state: ModelState = .idle,
                showError: Bool = false,
                errorMessage: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                systemPrompt: String = "",
                topic: String? = nil,
                description: String? = nil,
                isModelAvailable: Bool = true,
                agenticPhase: ConversationAgenticPhase = .idle,
                llmRequestPhase: ConversationLLMRequestPhase? = nil,
                interactionMode: InteractionMode = .chat,
                modeProfileID: String? = nil,
                thinkingEnabled: Bool = true,
                reasoningEffort: ConversationReasoningEffort? = nil,
                metadata: JSON? = nil,
                splitFromConversationID: UUID? = nil,
                splitThreadAfterMessageID: UUID? = nil) {
        self.init(
            id: id,
            model: model,
            messages: messages,
            turns: turns,
            state: state,
            showError: showError,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt,
            systemPrompt: systemPrompt,
            topic: topic,
            description: description,
            isModelAvailable: isModelAvailable,
            agenticPhase: agenticPhase,
            llmRequestPhase: llmRequestPhase,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            metadata: metadata,
            splitFromConversationID: splitFromConversationID,
            splitThreadAfterMessageID: splitThreadAfterMessageID,
            lifecycle: .active,
            resourceRunStatus: .idle,
            currentRunID: nil,
            parentConversationID: nil,
            ownerAccountID: nil,
            extraInstructions: nil,
            routingPrefs: nil,
            budgetSnapshot: nil,
            branchChildren: [],
            attachmentsCatalog: [],
            tags: [],
            lastActiveAt: nil,
            controlPlaneRevision: 0,
            harnessPersistenceSource: nil,
            harnessPersistenceTrustClass: nil,
            harnessPersistenceAgentId: nil,
            harnessPersistenceCwd: nil
        )
        self.thinkingEnabled = thinkingEnabled
        if let reasoningEffort {
            self.reasoningEffort = reasoningEffort
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        model = try container.decode(Model.self, forKey: .model)
        messages = try container.decode([Message].self, forKey: .messages)
        turns = try container.decodeIfPresent([ConversationTurn].self, forKey: .turns) ?? []
        state = try container.decode(ModelState.self, forKey: .state)
        showError = try container.decode(Bool.self, forKey: .showError)
        errorMessage = try container.decode(String.self, forKey: .errorMessage)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isModelAvailable = try container.decodeIfPresent(Bool.self, forKey: .isModelAvailable) ?? true
        agenticPhase = try container.decodeIfPresent(ConversationAgenticPhase.self, forKey: .agenticPhase) ?? .idle
        llmRequestPhase = try container.decodeIfPresent(ConversationLLMRequestPhase.self, forKey: .llmRequestPhase)
        interactionMode = try container.decodeIfPresent(InteractionMode.self, forKey: .interactionMode) ?? .chat
        modeProfileID = try container.decodeIfPresent(String.self, forKey: .modeProfileID)
        metadata = try container.decodeIfPresent(JSON.self, forKey: .metadata)
        splitFromConversationID = try container.decodeIfPresent(UUID.self, forKey: .splitFromConversationID)
        splitThreadAfterMessageID = try container.decodeIfPresent(UUID.self, forKey: .splitThreadAfterMessageID)
        lifecycle = try container.decodeIfPresent(ConversationLifecycleState.self, forKey: .lifecycle) ?? .active
        resourceRunStatus = try container.decodeIfPresent(ConversationResourceRunStatus.self, forKey: .resourceRunStatus) ?? .idle
        currentRunID = try container.decodeIfPresent(UUID.self, forKey: .currentRunID)
        parentConversationID = try container.decodeIfPresent(UUID.self, forKey: .parentConversationID)
        ownerAccountID = try container.decodeIfPresent(UUID.self, forKey: .ownerAccountID)
        extraInstructions = try container.decodeIfPresent(String.self, forKey: .extraInstructions)
        systemPromptFullOverride = try container.decodeIfPresent(Bool.self, forKey: .systemPromptFullOverride) ?? false
        routingPrefs = try container.decodeIfPresent(ConversationRoutingPrefs.self, forKey: .routingPrefs)
        budgetSnapshot = try container.decodeIfPresent(ConversationBudgetSnapshot.self, forKey: .budgetSnapshot)
        branchChildren = try container.decodeIfPresent([ConversationBranchRef].self, forKey: .branchChildren) ?? []
        attachmentsCatalog = try container.decodeIfPresent([ConversationAttachmentDescriptor].self, forKey: .attachmentsCatalog) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        controlPlaneRevision = try container.decodeIfPresent(UInt64.self, forKey: .controlPlaneRevision) ?? 0
        harnessPersistenceSource = try container.decodeIfPresent(String.self, forKey: .harnessPersistenceSource)
        harnessPersistenceTrustClass = try container.decodeIfPresent(String.self, forKey: .harnessPersistenceTrustClass)
        harnessPersistenceAgentId = try container.decodeIfPresent(String.self, forKey: .harnessPersistenceAgentId)
        harnessPersistenceCwd = try container.decodeIfPresent(String.self, forKey: .harnessPersistenceCwd)
        transcriptIntegrity = try container.decodeIfPresent(ConversationTranscriptIntegrity.self, forKey: .transcriptIntegrity)
        lineageKind = try container.decodeIfPresent(ConversationLineageKind.self, forKey: .lineageKind) ?? .root
        origin = try container.decodeIfPresent(ConversationOrigin.self, forKey: .origin) ?? .user
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(turns, forKey: .turns)
        try container.encode(state, forKey: .state)
        try container.encode(showError, forKey: .showError)
        try container.encode(errorMessage, forKey: .errorMessage)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(topic, forKey: .topic)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(isModelAvailable, forKey: .isModelAvailable)
        try container.encode(agenticPhase, forKey: .agenticPhase)
        try container.encodeIfPresent(llmRequestPhase, forKey: .llmRequestPhase)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encodeIfPresent(modeProfileID, forKey: .modeProfileID)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(splitFromConversationID, forKey: .splitFromConversationID)
        try container.encodeIfPresent(splitThreadAfterMessageID, forKey: .splitThreadAfterMessageID)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(resourceRunStatus, forKey: .resourceRunStatus)
        try container.encodeIfPresent(currentRunID, forKey: .currentRunID)
        try container.encodeIfPresent(parentConversationID, forKey: .parentConversationID)
        try container.encodeIfPresent(ownerAccountID, forKey: .ownerAccountID)
        try container.encodeIfPresent(extraInstructions, forKey: .extraInstructions)
        if systemPromptFullOverride {
            try container.encode(systemPromptFullOverride, forKey: .systemPromptFullOverride)
        }
        try container.encodeIfPresent(routingPrefs, forKey: .routingPrefs)
        try container.encodeIfPresent(budgetSnapshot, forKey: .budgetSnapshot)
        if !branchChildren.isEmpty {
            try container.encode(branchChildren, forKey: .branchChildren)
        }
        if !attachmentsCatalog.isEmpty {
            try container.encode(attachmentsCatalog, forKey: .attachmentsCatalog)
        }
        if !tags.isEmpty {
            try container.encode(tags, forKey: .tags)
        }
        try container.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
        try container.encode(controlPlaneRevision, forKey: .controlPlaneRevision)
        try container.encodeIfPresent(harnessPersistenceSource, forKey: .harnessPersistenceSource)
        try container.encodeIfPresent(harnessPersistenceTrustClass, forKey: .harnessPersistenceTrustClass)
        try container.encodeIfPresent(harnessPersistenceAgentId, forKey: .harnessPersistenceAgentId)
        try container.encodeIfPresent(harnessPersistenceCwd, forKey: .harnessPersistenceCwd)
        try container.encodeIfPresent(transcriptIntegrity, forKey: .transcriptIntegrity)
        try container.encode(lineageKind, forKey: .lineageKind)
        try container.encode(origin, forKey: .origin)
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, messages, turns, state, showError, errorMessage, createdAt, updatedAt, systemPrompt, topic, description, isModelAvailable, agenticPhase, llmRequestPhase, interactionMode, modeProfileID, metadata, splitFromConversationID, splitThreadAfterMessageID
        case lifecycle, resourceRunStatus, currentRunID, parentConversationID, ownerAccountID, extraInstructions, systemPromptFullOverride, routingPrefs, budgetSnapshot, branchChildren, attachmentsCatalog, tags, lastActiveAt, controlPlaneRevision
        case harnessPersistenceSource, harnessPersistenceTrustClass, harnessPersistenceAgentId, harnessPersistenceCwd, transcriptIntegrity, lineageKind, origin
    }
}
