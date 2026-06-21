import Foundation
import SwiftAgentKit

// AI model
public struct Model: Identifiable, Sendable {
    public var id: UUID
    public var `protocol`: ModelProtocol
    public var modelName: String
    public var serverURL: URL
    /// A list of model capabilities (like vision, tools)
    public var capabilities: [LLMCapability]
    public var modelProtocol: ModelProtocol
    /// Maximum context length in tokens, when known (e.g. from Ollama model info).
    public var maxContextLength: Int?
    /// Per-call request knobs this model honors (streaming, response formats, parallel tools, reasoning efforts).
    public var requestFeatures: ModelRequestFeatures
    /// Optional cost metadata used by Model Pool ranking and budget projections.
    public var cost: ModelCostBudget?
    /// Rolling observed performance telemetry from runtime calls.
    public var performance: ModelObservedPerformance?
    /// Optional routing metadata surfaced through the model registry.
    public var routing: ModelRoutingMetadata?

    public init(id: UUID = UUID(),
                protocol: ModelProtocol,
                modelName: String,
                serverURL: URL,
                capabilities: [LLMCapability] = [],
                modelProtocol: ModelProtocol = .openAIAPI,
                maxContextLength: Int? = nil,
                requestFeatures: ModelRequestFeatures = .unknown,
                cost: ModelCostBudget? = nil,
                performance: ModelObservedPerformance? = nil,
                routing: ModelRoutingMetadata? = nil) {
        self.id = id
        self.protocol = `protocol`
        self.modelName = modelName
        self.serverURL = serverURL
        self.capabilities = capabilities
        self.modelProtocol = modelProtocol
        self.maxContextLength = maxContextLength
        self.requestFeatures = requestFeatures
        self.cost = cost
        self.performance = performance
        self.routing = routing
    }
}

extension Model: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, modelName, serverURL, capabilities, modelProtocol, maxContextLength, requestFeatures, cost, performance, routing
        case `protocol` = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        modelProtocol = try c.decode(ModelProtocol.self, forKey: .modelProtocol)
        `protocol` = try c.decode(ModelProtocol.self, forKey: .protocol)
        modelName = try c.decode(String.self, forKey: .modelName)
        serverURL = try c.decode(URL.self, forKey: .serverURL)
        capabilities = try c.decode([LLMCapability].self, forKey: .capabilities)
        maxContextLength = try c.decodeIfPresent(Int.self, forKey: .maxContextLength)
        requestFeatures = try c.decodeIfPresent(ModelRequestFeatures.self, forKey: .requestFeatures) ?? .unknown
        cost = try c.decodeIfPresent(ModelCostBudget.self, forKey: .cost)
        performance = try c.decodeIfPresent(ModelObservedPerformance.self, forKey: .performance)
        routing = try c.decodeIfPresent(ModelRoutingMetadata.self, forKey: .routing)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(modelProtocol, forKey: .modelProtocol)
        try c.encode(`protocol`, forKey: .protocol)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(serverURL, forKey: .serverURL)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encodeIfPresent(maxContextLength, forKey: .maxContextLength)
        try c.encode(requestFeatures, forKey: .requestFeatures)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(performance, forKey: .performance)
        try c.encodeIfPresent(routing, forKey: .routing)
    }
}
