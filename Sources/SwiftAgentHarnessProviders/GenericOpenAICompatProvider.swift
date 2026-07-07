import Foundation
import Logging
import SwiftAgentKit
import SwiftAgentHarness

public struct GenericOpenAICompatProvider: TextInferenceProviding {
    public let manifest: ProviderManifest
    public let config: ProviderInstanceConfig
    public let modelProtocol: ModelProtocol = .openAIAPI

    public init(manifest: ProviderManifest, config: ProviderInstanceConfig) {
        self.manifest = manifest
        self.config = config
    }

    public func staticCatalogEntries() -> [ProviderCatalogEntry] {
        if let catalog = config.resolvedCatalogEntries() {
            return catalog
        }
        return bundledStaticCatalogEntries(providerID: manifest.id)
    }

    public func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        let serverURL = manifest.defaultEndpoint?.baseURL ?? URL(string: "http://127.0.0.1:8080/v1")!
        let discovered = await probeModelsEndpoint(baseURL: serverURL, logger: logger)
        if discovered.isEmpty {
            return staticCatalogEntries().map {
                $0.toRegistryEntry(providerID: manifest.id, serverURL: serverURL)
            }
        }
        return discovered
    }

    public func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        ProviderLLMBridge.makeOpenAIAdapter(context: context)
    }

    public func failoverError(_ error: Error) -> ProviderFailoverClassification {
        if DefaultProviderFailoverClassifier.isCredentialExhausted(error) {
            return .credentialExhausted
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }

    private func probeModelsEndpoint(baseURL: URL, logger: Logger?) async -> [ModelRegistryEntry] {
        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            struct ModelsResponse: Decodable {
                struct Row: Decodable { var id: String }
                var data: [Row]
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { row in
                ProviderCatalogEntry(
                    registryID: ProviderCatalogStableID.registryUUID(
                        providerID: manifest.id,
                        endpointModelId: row.id
                    ),
                    endpointModelId: row.id,
                    displayName: row.id,
                    modelConfig: ModelConfig(
                        uuid: ProviderCatalogStableID.registryUUID(
                            providerID: manifest.id,
                            endpointModelId: row.id
                        ),
                        modelProtocol: .openAIAPI
                    )
                ).toRegistryEntry(providerID: manifest.id, serverURL: baseURL)
            }
        } catch {
            logger?.warning("[GenericOpenAICompatProvider] GET /v1/models failed: \(error)")
            return []
        }
    }
}
