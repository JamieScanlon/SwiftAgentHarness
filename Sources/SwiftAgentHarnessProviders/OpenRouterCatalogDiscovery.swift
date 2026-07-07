import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentHarness

public struct OpenRouterModelsResponse: Codable, Sendable {
    public var data: [OpenRouterModelRow]
}

public struct OpenRouterModelRow: Codable, Sendable {
    public var id: String
    public var name: String?
    public var context_length: Int?
    public var pricing: OpenRouterModelPricing?
    public var architecture: OpenRouterModelArchitecture?

    public init(
        id: String,
        name: String? = nil,
        context_length: Int? = nil,
        pricing: OpenRouterModelPricing? = nil,
        architecture: OpenRouterModelArchitecture? = nil
    ) {
        self.id = id
        self.name = name
        self.context_length = context_length
        self.pricing = pricing
        self.architecture = architecture
    }
}

public struct OpenRouterModelPricing: Codable, Sendable {
    public var prompt: String?
    public var completion: String?
    public var input_cache_read: String?

    public init(prompt: String? = nil, completion: String? = nil, input_cache_read: String? = nil) {
        self.prompt = prompt
        self.completion = completion
        self.input_cache_read = input_cache_read
    }
}

public struct OpenRouterModelArchitecture: Codable, Sendable {
    public var modality: String?
    public var input_modalities: [String]?
    public var output_modalities: [String]?

    public init(
        modality: String? = nil,
        input_modalities: [String]? = nil,
        output_modalities: [String]? = nil
    ) {
        self.modality = modality
        self.input_modalities = input_modalities
        self.output_modalities = output_modalities
    }
}

public enum OpenRouterCatalogDiscovery {
    public typealias FetchModels = @Sendable (URL, Logger?) async throws -> [OpenRouterModelRow]

    public static func discoverEntries(
        manifest: ProviderManifest,
        staticEntries: [ProviderCatalogEntry],
        logger: Logger?,
        fetchModels: FetchModels? = nil
    ) async -> [ModelRegistryEntry] {
        guard let endpoint = manifest.defaultEndpoint else { return [] }
        let staticByID = Dictionary(uniqueKeysWithValues: staticEntries.map { ($0.endpointModelId, $0) })
        let fetch = fetchModels ?? defaultFetchModels

        let apiRows: [OpenRouterModelRow]
        do {
            apiRows = try await fetch(endpoint.baseURL, logger)
        } catch {
            logger?.warning("OpenRouter: failed to list models (GET /models): \(error)")
            return staticEntries.map {
                $0.toRegistryEntry(providerID: manifest.id, serverURL: endpoint.baseURL)
            }
        }

        var mergedByID: [String: ProviderCatalogEntry] = staticByID
        for row in apiRows {
            if let staticEntry = staticByID[row.id] {
                mergedByID[row.id] = staticEntry
            } else {
                mergedByID[row.id] = catalogEntry(from: row, providerID: manifest.id)
            }
        }

        return mergedByID.values
            .sorted { $0.endpointModelId < $1.endpointModelId }
            .map { $0.toRegistryEntry(providerID: manifest.id, serverURL: endpoint.baseURL) }
    }

    public static func resolveDynamicModel(
        context: ProviderDynamicModelContext,
        providerID: ProviderID,
        staticEntries: [ProviderCatalogEntry]
    ) -> ProviderCatalogEntry? {
        if let staticEntry = staticEntries.first(where: { $0.endpointModelId == context.endpointModelId }) {
            return staticEntry
        }
        return catalogEntry(
            endpointModelId: context.endpointModelId,
            displayName: context.endpointModelId,
            providerID: providerID,
            contextLength: nil,
            cost: nil,
            capabilities: [.completion]
        )
    }

    static func catalogEntry(from row: OpenRouterModelRow, providerID: ProviderID) -> ProviderCatalogEntry {
        catalogEntry(
            endpointModelId: row.id,
            displayName: row.name ?? row.id,
            providerID: providerID,
            contextLength: row.context_length,
            cost: costBudget(from: row.pricing),
            capabilities: capabilities(from: row)
        )
    }

    private static func catalogEntry(
        endpointModelId: String,
        displayName: String,
        providerID: ProviderID,
        contextLength: Int?,
        cost: ModelCostBudget?,
        capabilities: Set<LLMCapability>
    ) -> ProviderCatalogEntry {
        let registryID = ProviderCatalogStableID.registryUUID(
            providerID: providerID,
            endpointModelId: endpointModelId
        )
        let modelConfig = ModelConfig(
            uuid: registryID,
            modelProtocol: .openAIAPI,
            hardcodedCapabilities: Array(capabilities),
            hardcodedCost: cost
        )
        return ProviderCatalogEntry(
            registryID: registryID,
            endpointModelId: endpointModelId,
            displayName: displayName,
            modelConfig: modelConfig,
            maxContextLength: contextLength,
            capabilities: capabilities
        )
    }

    public static func costBudget(from pricing: OpenRouterModelPricing?) -> ModelCostBudget? {
        guard let pricing else { return nil }
        let input = pricing.prompt.flatMap { perTokenUSDToPer1M($0) }
        let output = pricing.completion.flatMap { perTokenUSDToPer1M($0) }
        let cached = pricing.input_cache_read.flatMap { perTokenUSDToPer1M($0) }
        guard input != nil || output != nil || cached != nil else { return nil }
        return ModelCostBudget(
            inputPer1MUSD: input,
            outputPer1MUSD: output,
            cachedInputPer1MUSD: cached
        )
    }

    public static func perTokenUSDToPer1M(_ raw: String) -> Double? {
        guard let value = Double(raw) else { return nil }
        return value * 1_000_000.0
    }

    static func capabilities(from row: OpenRouterModelRow) -> Set<LLMCapability> {
        var caps: Set<LLMCapability> = [.completion]
        let modality = row.architecture?.modality?.lowercased() ?? ""
        let inputs = Set((row.architecture?.input_modalities ?? []).map { $0.lowercased() })
        let outputs = Set((row.architecture?.output_modalities ?? []).map { $0.lowercased() })

        if modality.contains("image") || inputs.contains("image") {
            caps.insert(.vision)
        }
        if modality.contains("audio") || inputs.contains("audio") {
            caps.insert(.audio)
        }
        if outputs.contains("image") {
            caps.insert(.imageGeneration)
        }
        caps.insert(.tools)
        return caps
    }

    private static func defaultFetchModels(baseURL: URL, logger: Logger?) async throws -> [OpenRouterModelRow] {
        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data).data
    }
}
