import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Model state wire JSON")
struct ModelStateWireFormatTests {
    @Test("CommResourceTopicMessage encodes snapshot envelope keys")
    func snapshotEnvelopeKeys() throws {
        let modelID = UUID()
        let payload = ModelStatePayload(phase: .streaming, thinking: false, callId: nil, updatedAt: Date(timeIntervalSince1970: 0))
        let topic = ModelStateTopicFormat.topic(modelID: modelID)
        let msg = CommResourceTopicMessage<ModelStatePayload>(snapshot: topic, seq: 3, value: payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["kind"] as? String == "snapshot")
        #expect(json?["topic"] as? String == topic)
        #expect(json?["trustClass"] as? String == "trusted")
        #expect(json?["originTrust"] as? String == "system")
        #expect(json?["seq"] as? Int == 3)
        #expect(json?["value"] is [String: Any])
    }

    @Test("pool/health envelope encodes value fields")
    func poolHealthEnvelopeKeys() throws {
        let payload = PoolHealthPayload(
            queueDepth: 2,
            inFlight: 3,
            maxConcurrent: 8,
            errorRate: 0.25,
            rollingLatencyMsP50: 120,
            rollingLatencyMsP95: 260
        )
        let msg = CommResourceTopicMessage<PoolHealthPayload>(
            snapshot: ResourceTopicName.poolHealth,
            seq: 1,
            value: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let value = json?["value"] as? [String: Any]
        #expect(value?["queueDepth"] as? Int == 2)
        #expect(value?["inFlight"] as? Int == 3)
        #expect(value?["maxConcurrent"] as? Int == 8)
        #expect(value?["errorRate"] as? Double == 0.25)
        #expect(value?["rollingLatencyMsP50"] as? Double == 120)
        #expect(value?["rollingLatencyMsP95"] as? Double == 260)
    }

    @Test("ModelStatePayload roundtrips inFlightCount through JSON")
    func inFlightCountRoundTrip() throws {
        let payload = ModelStatePayload(
            phase: .streaming,
            thinking: true,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 0),
            inFlightCount: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelStatePayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.inFlightCount == 3)
    }

    @Test("ModelStatePayload roundtrips communication aggregate fields")
    func modelStateAggregateRoundTrip() throws {
        let payload = ModelStatePayload(
            phase: .errored,
            thinking: false,
            callId: UUID(),
            updatedAt: Date(timeIntervalSince1970: 0),
            inFlightCount: 1,
            lastCompletedAt: Date(timeIntervalSince1970: 1),
            recentLatencyMsP50: 140,
            recentLatencyMsP95: 220,
            recentTokensPerSecond: 55,
            rateLimitWindow: ModelRateLimitWindow(
                active: true,
                lastObservedAt: Date(timeIntervalSince1970: 2),
                retryAfterSeconds: nil
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelStatePayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("models/registry envelope encodes models array")
    func modelsRegistryEnvelopeKeys() throws {
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "m",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let payload = ModelsRegistryPayload(models: [model])
        let msg = CommResourceTopicMessage<ModelsRegistryPayload>(
            snapshot: ResourceTopicName.modelsRegistry,
            seq: 1,
            value: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["topic"] as? String == ResourceTopicName.modelsRegistry)
        let value = json?["value"] as? [String: Any]
        let models = value?["models"] as? [Any]
        #expect(models?.count == 1)
    }

    /// `GET /api/models` uses `[Model.toModelInfo()]`; `models/registry` snapshots embed full `Model` rows.
    /// Clients derive `ModelInfo` via the same projection; this test freezes that equivalence after JSON round-trip.
    @Test("models/registry snapshot model row matches REST ModelInfo projection")
    func modelsRegistryMatchesRESTModelInfoProjection() throws {
        let model = Model(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-A1B2-C3D4E5F67890")!,
            protocol: .openAIAPI,
            modelName: "parity-model",
            serverURL: URL(string: "http://127.0.0.1:9999/v1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 8192,
            requestFeatures: .unknown,
            cost: ModelCostBudget(inputPer1MUSD: 0.1, outputPer1MUSD: 0.3, cachedInputPer1MUSD: 0.02),
            routing: ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 20, tokens: 300_000, windowMs: 60_000)
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let expectedInfo = model.toModelInfo()

        let payload = ModelsRegistryPayload(models: [model])
        let payloadData = try encoder.encode(payload)
        let decodedPayload = try decoder.decode(ModelsRegistryPayload.self, from: payloadData)
        let roundTripModel = try #require(decodedPayload.models.first)
        try assertModelInfoEquivalent(roundTripModel.toModelInfo(), expectedInfo)

        let restData = try encoder.encode(ListModelsRESTShape(models: [expectedInfo]))
        let restDecoded = try decoder.decode(ListModelsRESTShape.self, from: restData)
        let fromREST = try #require(restDecoded.models.first)
        try assertModelInfoEquivalent(fromREST, expectedInfo)
    }
}

private struct ListModelsRESTShape: Codable {
    let models: [ModelInfo]
}

private func assertModelInfoEquivalent(_ lhs: ModelInfo, _ rhs: ModelInfo) throws {
    #expect(lhs.id == rhs.id)
    #expect(lhs.modelName == rhs.modelName)
    #expect(lhs.modelProtocol == rhs.modelProtocol)
    #expect(lhs.capabilities == rhs.capabilities)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let lhsFeaturesData = try enc.encode(lhs.requestFeatures)
    let rhsFeaturesData = try enc.encode(rhs.requestFeatures)
    #expect(lhsFeaturesData == rhsFeaturesData)
    #expect(lhs.cost == rhs.cost)
    #expect(lhs.routing == rhs.routing)
}
