import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Communication layer enrichment — wire round-trip")
struct CommunicationLayerEnrichmentWireTests {
    private static func iso8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - ModelStatePayload.lastCompletedAt

    @Test("ModelStatePayload roundtrips lastCompletedAt")
    func modelStateLastCompletedAtRoundTrip() throws {
        let lastCompleted = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ModelStatePayload(
            phase: .done,
            thinking: false,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            inFlightCount: nil,
            lastCompletedAt: lastCompleted
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ModelStatePayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.lastCompletedAt == lastCompleted)
    }

    @Test("ModelStatePayload omits lastCompletedAt when nil")
    func modelStateLastCompletedAtOmitted() throws {
        let payload = ModelStatePayload(phase: .connecting, thinking: false)
        let data = try Self.iso8601Encoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?.keys.contains("lastCompletedAt") == false)
    }

    // MARK: - PoolHealthPayload.queueDepthByPriority + budgetRemaining

    @Test("PoolHealthPayload roundtrips queueDepthByPriority")
    func poolHealthQueueDepthByPriorityRoundTrip() throws {
        let payload = PoolHealthPayload(
            queueDepth: 4,
            inFlight: 1,
            maxConcurrent: 8,
            updatedAt: Date(timeIntervalSince1970: 0),
            queueDepthByPriority: PoolHealthQueueDepth(foreground: 3, background: 1)
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(PoolHealthPayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.queueDepthByPriority?.foreground == 3)
        #expect(decoded.queueDepthByPriority?.background == 1)
    }

    @Test("PoolHealthPayload roundtrips budgetRemaining when populated")
    func poolHealthBudgetRemainingRoundTrip() throws {
        var payload = PoolHealthPayload(
            queueDepth: 0,
            inFlight: 0,
            maxConcurrent: 8,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        payload.budgetRemaining = 12.34
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(PoolHealthPayload.self, from: data)
        #expect(decoded.budgetRemaining == 12.34)
    }

    @Test("PoolHealthPayload omits new optional fields when nil")
    func poolHealthOmitsNilFields() throws {
        let payload = PoolHealthPayload(queueDepth: 0, inFlight: 0, maxConcurrent: 8)
        let data = try Self.iso8601Encoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?.keys.contains("queueDepthByPriority") == false)
        #expect(json?.keys.contains("budgetRemaining") == false)
        #expect(json?.keys.contains("errorRate") == false)
        #expect(json?.keys.contains("rollingLatencyMsP50") == false)
        #expect(json?.keys.contains("rollingLatencyMsP95") == false)
    }

    @Test("PoolHealthPayload roundtrips rolling latency aggregates")
    func poolHealthLatencyAggregatesRoundTrip() throws {
        let payload = PoolHealthPayload(
            queueDepth: 1,
            inFlight: 2,
            maxConcurrent: 8,
            updatedAt: Date(timeIntervalSince1970: 10),
            errorRate: 0.5,
            budgetRemaining: 5.0,
            queueDepthByPriority: PoolHealthQueueDepth(foreground: 1, background: 0),
            rollingLatencyMsP50: 123.0,
            rollingLatencyMsP95: 456.0
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(PoolHealthPayload.self, from: data)
        #expect(decoded.rollingLatencyMsP50 == 123.0)
        #expect(decoded.rollingLatencyMsP95 == 456.0)
    }

    @Test("ModelStatePayload roundtrips recent latency and rate-limit window")
    func modelStateRecentLatencyAndRateLimitRoundTrip() throws {
        let payload = ModelStatePayload(
            phase: .errored,
            thinking: false,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 11),
            inFlightCount: 0,
            lastCompletedAt: Date(timeIntervalSince1970: 12),
            recentLatencyMsP50: 222.0,
            recentLatencyMsP95: 333.0,
            rateLimitWindow: ModelRateLimitWindow(
                active: true,
                lastObservedAt: Date(timeIntervalSince1970: 13),
                retryAfterSeconds: nil
            )
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ModelStatePayload.self, from: data)
        #expect(decoded.recentLatencyMsP50 == 222.0)
        #expect(decoded.recentLatencyMsP95 == 333.0)
        #expect(decoded.rateLimitWindow?.active == true)
        #expect(decoded.rateLimitWindow?.lastObservedAt == Date(timeIntervalSince1970: 13))
    }

    // MARK: - ConversationStatePayload new fields

    @Test("ConversationStatePayload roundtrips activeModelID/activeCallID/contextBudget/projectedCostUSD")
    func conversationStateNewFieldsRoundTrip() throws {
        let conversationID = UUID()
        let activeModelID = UUID()
        let activeCallID = UUID()
        let payload = ConversationStatePayload(
            conversationID: conversationID,
            exists: true,
            sessionSelected: true,
            activeModelID: activeModelID,
            activeCallID: activeCallID,
            contextBudget: ConversationContextBudget(
                contextLimitTokens: 8_192,
                promptTokens: 1_024,
                remainingTokens: 7_168
            ),
            projectedCostUSD: 0.42
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ConversationStatePayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.activeModelID == activeModelID)
        #expect(decoded.activeCallID == activeCallID)
        #expect(decoded.contextBudget?.contextLimitTokens == 8_192)
        #expect(decoded.contextBudget?.promptTokens == 1_024)
        #expect(decoded.contextBudget?.remainingTokens == 7_168)
        #expect(decoded.projectedCostUSD == 0.42)
    }

    @Test("ConversationStatePayload omits new optional fields when nil")
    func conversationStateOmitsNewFieldsWhenNil() throws {
        let payload = ConversationStatePayload(
            conversationID: UUID(),
            exists: true,
            sessionSelected: false
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?.keys.contains("activeModelID") == false)
        #expect(json?.keys.contains("activeCallID") == false)
        #expect(json?.keys.contains("contextBudget") == false)
        #expect(json?.keys.contains("projectedCostUSD") == false)
        #expect(json?.keys.contains("attachmentsCatalog") == false)
    }

    @Test("ConversationStatePayload roundtrips attachmentsCatalog when populated")
    func conversationStateAttachmentsCatalogRoundTrip() throws {
        let conversationID = UUID()
        let aid = UUID()
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let att = ConversationAttachmentDescriptor(
            id: aid,
            kind: "file",
            name: "notes.txt",
            mimeType: "text/plain",
            byteSize: 12,
            addedAt: addedAt,
            addedBy: .user,
            trustRaw: "user_direct"
        )
        let payload = ConversationStatePayload(
            conversationID: conversationID,
            exists: true,
            sessionSelected: true,
            attachmentsCatalog: [att]
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ConversationStatePayload.self, from: data)
        #expect(decoded.attachmentsCatalog?.count == 1)
        #expect(decoded.attachmentsCatalog?.first == att)
    }

    @Test("ConversationStatePayload.deleted clears all enrichment fields")
    func deletedClearsEnrichmentFields() {
        let id = UUID()
        let payload = ConversationStatePayload.deleted(conversationID: id)
        #expect(payload.activeModelID == nil)
        #expect(payload.activeCallID == nil)
        #expect(payload.contextBudget == nil)
        #expect(payload.projectedCostUSD == nil)
        #expect(payload.lifecycle == nil)
        #expect(payload.parentConversationID == nil)
        #expect(payload.tags == nil)
        #expect(payload.resourceBudgetSnapshot == nil)
        #expect(payload.branchChildren == nil)
        #expect(payload.resourceRunStatus == nil)
        #expect(payload.currentRunID == nil)
        #expect(payload.attachmentsCatalog == nil)
    }

    // MARK: - ConversationCheckpointTopicEventWire (events topic `checkpoint`)

    @Test("ConversationCheckpointTopicEventWire roundtrips JSON")
    func conversationCheckpointTopicEventWireRoundTrip() throws {
        let cid = UUID()
        let wire = ConversationCheckpointTopicEventWire(
            variant: .contextCompactionCheckpoint,
            conversationID: cid,
            harnessCheckpointKind: "context_compaction",
            compactionCheckpointKind: "pruned",
            coveredRawMessageIDs: [.generate()],
            basedOnTailMessageID: nil,
            invalidatedCheckpointKinds: nil
        )
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(ConversationCheckpointTopicEventWire.self, from: data)
        #expect(decoded == wire)
    }

    // MARK: - ModelsRegistryEventPayload per ChangeKind

    private static func makeModel(name: String) -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            routing: ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 20, tokens: 300_000, windowMs: 60_000)
            )
        )
    }

    @Test("ModelsRegistryEventPayload roundtrips .added with current populated, previous nil")
    func registryEventAddedRoundTrip() throws {
        let model = Self.makeModel(name: "added")
        let payload = ModelsRegistryEventPayload(
            changes: [ModelRegistryChange(kind: .added, modelID: model.id, previous: nil, current: model)],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ModelsRegistryEventPayload.self, from: data)
        #expect(decoded.changes.count == 1)
        #expect(decoded.changes[0].kind == .added)
        #expect(decoded.changes[0].modelID == model.id)
        #expect(decoded.changes[0].previous == nil)
        #expect(decoded.changes[0].current?.modelName == "added")
    }

    @Test("ModelsRegistryEventPayload roundtrips .removed with previous populated, current nil")
    func registryEventRemovedRoundTrip() throws {
        let model = Self.makeModel(name: "removed")
        let payload = ModelsRegistryEventPayload(
            changes: [ModelRegistryChange(kind: .removed, modelID: model.id, previous: model, current: nil)]
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ModelsRegistryEventPayload.self, from: data)
        #expect(decoded.changes[0].kind == .removed)
        #expect(decoded.changes[0].current == nil)
        #expect(decoded.changes[0].previous?.modelName == "removed")
    }

    @Test("ModelsRegistryEventPayload roundtrips .updated with both previous and current populated")
    func registryEventUpdatedRoundTrip() throws {
        let id = UUID()
        let before = Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "before",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let after = Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "after",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let payload = ModelsRegistryEventPayload(
            changes: [ModelRegistryChange(kind: .updated, modelID: id, previous: before, current: after)]
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let decoded = try Self.iso8601Decoder().decode(ModelsRegistryEventPayload.self, from: data)
        #expect(decoded.changes[0].kind == .updated)
        #expect(decoded.changes[0].previous?.modelName == "before")
        #expect(decoded.changes[0].current?.modelName == "after")
    }

    @Test("ModelsRegistryEventPayload kind enum encodes as lowercase strings")
    func registryEventKindEncoding() throws {
        let payload = ModelsRegistryEventPayload(
            changes: [
                ModelRegistryChange(kind: .added, modelID: UUID(), current: Self.makeModel(name: "a")),
                ModelRegistryChange(kind: .removed, modelID: UUID(), previous: Self.makeModel(name: "r")),
                ModelRegistryChange(kind: .updated, modelID: UUID(),
                                    previous: Self.makeModel(name: "u1"),
                                    current: Self.makeModel(name: "u2"))
            ]
        )
        let data = try Self.iso8601Encoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let changes = json?["changes"] as? [[String: Any]] ?? []
        let kinds = changes.compactMap { $0["kind"] as? String }
        #expect(kinds == ["added", "removed", "updated"])
    }
}
