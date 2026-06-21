import Foundation
import SwiftAgentKit

/// Summary information about a model that can be deisplayed in a list UI
public struct ModelInfo: Sendable, Identifiable {
    public var id: UUID
    public var modelName: String
    public var modelProtocol: ModelProtocol
    public var capabilities: [LLMCapability]
    public var requestFeatures: ModelRequestFeatures
    public var cost: ModelCostBudget?
    public var routing: ModelRoutingMetadata?

    public init(
        id: UUID,
        modelName: String,
        modelProtocol: ModelProtocol,
        capabilities: [LLMCapability] = [.unknown],
        requestFeatures: ModelRequestFeatures = .unknown,
        cost: ModelCostBudget? = nil,
        routing: ModelRoutingMetadata? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.modelProtocol = modelProtocol
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.cost = cost
        self.routing = routing
    }

    public func toJSON() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id.uuidString,
            "modelName": modelName,
            "modelProtocol": modelProtocol,
            "capabilities": capabilities.map(\.rawValue),
        ]
        if let data = try? JSONEncoder().encode(requestFeatures),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            payload["requestFeatures"] = obj
        }
        if let cost {
            if let data = try? JSONEncoder().encode(cost),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                payload["cost"] = obj
            }
        }
        if let routing {
            if let data = try? JSONEncoder().encode(routing),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                payload["routing"] = obj
            }
        }
        return payload
    }
}

extension ModelInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, modelName, modelProtocol, capabilities, requestFeatures, cost, routing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        modelName = try c.decode(String.self, forKey: .modelName)
        modelProtocol = try c.decode(ModelProtocol.self, forKey: .modelProtocol)
        capabilities = try c.decode([LLMCapability].self, forKey: .capabilities)
        requestFeatures = try c.decodeIfPresent(ModelRequestFeatures.self, forKey: .requestFeatures) ?? .unknown
        cost = try c.decodeIfPresent(ModelCostBudget.self, forKey: .cost)
        routing = try c.decodeIfPresent(ModelRoutingMetadata.self, forKey: .routing)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(modelProtocol, forKey: .modelProtocol)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(requestFeatures, forKey: .requestFeatures)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(routing, forKey: .routing)
    }
}
