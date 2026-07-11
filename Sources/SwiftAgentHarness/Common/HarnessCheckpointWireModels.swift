//
//  REST wire types for `GET …/checkpoints/latest` (multi-kind envelope).
//

import Foundation

/// Harness checkpoint discriminant strings for REST (`kind` query param + response `kind`).
public enum HarnessCheckpointWireKind: String, Codable, Sendable, CaseIterable {
    case contextCompaction = "context_compaction"
    case memoryInjectionSnapshot = "memory_injection_snapshot"
    case toolResultTrim = "tool_result_trim"
    case systemPromptAssembly = "system_prompt_assembly"
    case attachmentProjection = "attachment_projection"
}

public struct MemoryStoreSnapshotJSON: Codable, Sendable, Equatable {
    public var memoryEntryIDs: [UUID]
    public var memoryStoreVersion: Int
    public var selectedSelectionKeys: [String]?
    public var projectedSelectionKeys: [String]?

    public init(
        memoryEntryIDs: [UUID],
        memoryStoreVersion: Int,
        selectedSelectionKeys: [String]? = nil,
        projectedSelectionKeys: [String]? = nil
    ) {
        self.memoryEntryIDs = memoryEntryIDs
        self.memoryStoreVersion = memoryStoreVersion
        self.selectedSelectionKeys = selectedSelectionKeys
        self.projectedSelectionKeys = projectedSelectionKeys
    }
}

public struct PreCompactionMemoryFlushSnapshotJSON: Codable, Sendable, Equatable {
    public var kind: String
    public var memoryEntryIDs: [UUID]
    public var memoryStoreVersion: Int

    public init(kind: String = "pre_compaction_memory_flush", memoryEntryIDs: [UUID], memoryStoreVersion: Int) {
        self.kind = kind
        self.memoryEntryIDs = memoryEntryIDs
        self.memoryStoreVersion = memoryStoreVersion
    }
}

// MARK: - Per-kind wire payloads

public struct MemoryInjectionSnapshotCheckpointWire: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var basedOnEventID: Int
    public var injectionFingerprint: String
    public var snapshotJSON: String
    public var scopeMessageIDs: [UUID]
    public var memoryStoreVersion: Int?
    public var memoryStoreNamespaceKey: String?
    public var memoryEntryIDs: [UUID]?
    public var selectorConfigFingerprint: String?
    public var selectionContextMessageIDs: [UUID]?
    public var createdAt: Date

    public init(
        schemaVersion: Int,
        basedOnEventID: Int,
        injectionFingerprint: String,
        snapshotJSON: String,
        scopeMessageIDs: [UUID],
        memoryStoreVersion: Int? = nil,
        memoryStoreNamespaceKey: String? = nil,
        memoryEntryIDs: [UUID]? = nil,
        selectorConfigFingerprint: String? = nil,
        selectionContextMessageIDs: [UUID]? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.basedOnEventID = basedOnEventID
        self.injectionFingerprint = injectionFingerprint
        self.snapshotJSON = snapshotJSON
        self.scopeMessageIDs = scopeMessageIDs
        self.memoryStoreVersion = memoryStoreVersion
        self.memoryStoreNamespaceKey = memoryStoreNamespaceKey
        self.memoryEntryIDs = memoryEntryIDs
        self.selectorConfigFingerprint = selectorConfigFingerprint
        self.selectionContextMessageIDs = selectionContextMessageIDs
        self.createdAt = createdAt
    }
}

public struct ToolResultTrimCheckpointWire: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var basedOnEventID: Int
    public var coveredMessageIDs: [UUID]
    public var trimmedToolCallIds: [String]
    public var configFingerprint: String
    public var createdAt: Date

    public init(
        schemaVersion: Int,
        basedOnEventID: Int,
        coveredMessageIDs: [UUID],
        trimmedToolCallIds: [String],
        configFingerprint: String,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.basedOnEventID = basedOnEventID
        self.coveredMessageIDs = coveredMessageIDs
        self.trimmedToolCallIds = trimmedToolCallIds
        self.configFingerprint = configFingerprint
        self.createdAt = createdAt
    }
}

public struct SystemPromptAssemblyCheckpointWire: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var basedOnEventID: Int
    public var assemblyFingerprint: String
    public var assembledPromptDigest: String?
    public var replaySpecDigest: String?
    public var assembledPrompt: String?
    public var sectionProvenanceJSON: String?
    public var createdAt: Date

    public init(
        schemaVersion: Int,
        basedOnEventID: Int,
        assemblyFingerprint: String,
        assembledPromptDigest: String? = nil,
        replaySpecDigest: String? = nil,
        assembledPrompt: String? = nil,
        sectionProvenanceJSON: String? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.basedOnEventID = basedOnEventID
        self.assemblyFingerprint = assemblyFingerprint
        self.assembledPromptDigest = assembledPromptDigest
        self.replaySpecDigest = replaySpecDigest
        self.assembledPrompt = assembledPrompt
        self.sectionProvenanceJSON = sectionProvenanceJSON
        self.createdAt = createdAt
    }
}

public struct AttachmentProjectionCheckpointWire: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var basedOnEventID: Int
    public var projectionFingerprint: String
    public var decisions: [ConversationAttachmentProjectionDecision]
    public var createdAt: Date

    public init(
        schemaVersion: Int,
        basedOnEventID: Int,
        projectionFingerprint: String,
        decisions: [ConversationAttachmentProjectionDecision],
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.basedOnEventID = basedOnEventID
        self.projectionFingerprint = projectionFingerprint
        self.decisions = decisions
        self.createdAt = createdAt
    }
}

/// Discriminated checkpoint body (`checkpoint` JSON varies by top-level `kind`).
public enum LatestCheckpointPayload: Sendable, Equatable {
    case contextCompaction(ContextCompactionCheckpointWire)
    case memoryInjectionSnapshot(MemoryInjectionSnapshotCheckpointWire)
    case toolResultTrim(ToolResultTrimCheckpointWire)
    case systemPromptAssembly(SystemPromptAssemblyCheckpointWire)
    case attachmentProjection(AttachmentProjectionCheckpointWire)
}

/// Latest valid checkpoint for `GET /api/conversations/{id}/checkpoints/latest`.
public struct LatestCheckpointResponse: Codable, Sendable, Equatable {
    public var kind: String
    public var eventID: Int
    public var checkpoint: LatestCheckpointPayload

    enum CodingKeys: String, CodingKey {
        case kind
        case eventID
        case checkpoint
    }

    public init(kind: String, eventID: Int, checkpoint: LatestCheckpointPayload) {
        self.kind = kind
        self.eventID = eventID
        self.checkpoint = checkpoint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        eventID = try c.decode(Int.self, forKey: .eventID)
        checkpoint = try Self.decodePayload(kind: kind, container: c)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(eventID, forKey: .eventID)
        try encodePayload(checkpoint, to: &c)
    }

    private static func decodePayload(
        kind: String,
        container c: KeyedDecodingContainer<CodingKeys>
    ) throws -> LatestCheckpointPayload {
        switch kind {
        case HarnessCheckpointWireKind.contextCompaction.rawValue:
            return .contextCompaction(try c.decode(ContextCompactionCheckpointWire.self, forKey: .checkpoint))
        case HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue:
            return .memoryInjectionSnapshot(try c.decode(MemoryInjectionSnapshotCheckpointWire.self, forKey: .checkpoint))
        case HarnessCheckpointWireKind.toolResultTrim.rawValue:
            return .toolResultTrim(try c.decode(ToolResultTrimCheckpointWire.self, forKey: .checkpoint))
        case HarnessCheckpointWireKind.systemPromptAssembly.rawValue:
            return .systemPromptAssembly(try c.decode(SystemPromptAssemblyCheckpointWire.self, forKey: .checkpoint))
        case HarnessCheckpointWireKind.attachmentProjection.rawValue:
            return .attachmentProjection(try c.decode(AttachmentProjectionCheckpointWire.self, forKey: .checkpoint))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown harness checkpoint kind \(kind)"
            )
        }
    }

    private func encodePayload(_ payload: LatestCheckpointPayload, to c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch payload {
        case .contextCompaction(let wire):
            try c.encode(wire, forKey: .checkpoint)
        case .memoryInjectionSnapshot(let wire):
            try c.encode(wire, forKey: .checkpoint)
        case .toolResultTrim(let wire):
            try c.encode(wire, forKey: .checkpoint)
        case .systemPromptAssembly(let wire):
            try c.encode(wire, forKey: .checkpoint)
        case .attachmentProjection(let wire):
            try c.encode(wire, forKey: .checkpoint)
        }
    }
}
