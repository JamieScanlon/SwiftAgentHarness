import CryptoKit
import Foundation
import SwiftAgentKit

struct BundledCatalogCost: Codable, Sendable {
    var inputPer1MUSD: Double?
    var outputPer1MUSD: Double?
    var cachedInputPer1MUSD: Double?

    func toModelCostBudget() -> ModelCostBudget? {
        guard inputPer1MUSD != nil || outputPer1MUSD != nil || cachedInputPer1MUSD != nil else {
            return nil
        }
        return ModelCostBudget(
            inputPer1MUSD: inputPer1MUSD,
            outputPer1MUSD: outputPer1MUSD,
            cachedInputPer1MUSD: cachedInputPer1MUSD
        )
    }
}

struct BundledCatalogRequestFeatures: Codable, Sendable {
    var streaming: Bool?
    var responseFormats: [String]?
    var parallelToolCalls: String?
    var reasoningEfforts: [String]?
    var toolChoiceModes: [String]?

    func toModelRequestFeatures() -> ModelRequestFeatures? {
        guard streaming != nil
            || responseFormats != nil
            || parallelToolCalls != nil
            || reasoningEfforts != nil
            || toolChoiceModes != nil
        else {
            return nil
        }
        return ModelRequestFeatures(
            streaming: streaming ?? false,
            responseFormats: Set((responseFormats ?? []).compactMap { ResponseFormatKind(rawValue: $0) }),
            parallelToolCalls: parallelToolCalls.flatMap { decodeParallelToolCallSupport($0) } ?? .unsupported,
            reasoningEfforts: Set((reasoningEfforts ?? []).compactMap { ReasoningEffort(rawValue: $0) }),
            toolChoiceModes: Set((toolChoiceModes ?? []).compactMap { ToolChoiceMode(rawValue: $0) })
        )
    }

    private func decodeParallelToolCallSupport(_ raw: String) -> ParallelToolCallSupport? {
        switch raw {
        case "unsupported": return .unsupported
        case "uncapped": return .uncapped
        default:
            if raw.hasPrefix("capped("), raw.hasSuffix(")"), let value = Int(raw.dropFirst(6).dropLast(1)) {
                return .capped(value)
            }
            return nil
        }
    }
}

struct BundledCatalogModelRow: Codable, Sendable {
    var registryId: UUID
    var endpointModelId: String
    var displayName: String?
    var modelProtocol: String
    var capabilities: [String]?
    var maxContextLength: Int?
    var maxOutputTokens: Int?
    var cost: BundledCatalogCost?
    var requestFeatures: BundledCatalogRequestFeatures?
    var compat: ProviderModelCompat?
    var canonicalModelKey: String?
    var modelFamily: String?

    func toProviderCatalogEntry() -> ProviderCatalogEntry {
        let protocolValue = ModelProtocol(rawValue: modelProtocol) ?? .openAIAPI
        let modelConfig = ModelConfig(
            uuid: registryId,
            modelProtocol: protocolValue,
            hardcodedCapabilities: (capabilities ?? []).compactMap { LLMCapability(rawValue: $0) },
            hardcodedRequestFeatures: requestFeatures?.toModelRequestFeatures(),
            hardcodedCost: cost?.toModelCostBudget(),
            canonicalModelKey: canonicalModelKey,
            modelFamily: modelFamily
        )
        return ProviderCatalogEntry(
            registryID: registryId,
            endpointModelId: endpointModelId,
            displayName: displayName,
            modelConfig: modelConfig,
            maxContextLength: maxContextLength,
            maxOutputTokens: maxOutputTokens,
            capabilities: capabilities.flatMap { caps in
                let set = Set(caps.compactMap { LLMCapability(rawValue: $0) })
                return set.isEmpty ? nil : set
            },
            compat: compat,
            canonicalModelKey: canonicalModelKey,
            modelFamily: modelFamily
        )
    }
}

struct BundledProviderCatalogFile: Codable, Sendable {
    var providerId: String
    var generatedAt: String?
    var models: [BundledCatalogModelRow]
}

enum ProviderCatalogLoader {
    static func bundledCatalogData(for providerID: ProviderID) -> Data? {
        let candidates = [
            Bundle.module.url(
                forResource: providerID,
                withExtension: "catalog.json",
                subdirectory: "catalogs"
            ),
            Bundle.module.url(forResource: providerID, withExtension: "catalog.json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return nil }
        return try? Data(contentsOf: url)
    }

    static func decodeBundledCatalog(for providerID: ProviderID) throws -> [ProviderCatalogEntry] {
        guard let data = bundledCatalogData(for: providerID) else { return [] }
        let file = try JSONDecoder().decode(BundledProviderCatalogFile.self, from: data)
        guard file.providerId == providerID else {
            throw ProviderCatalogLoaderError.providerIDMismatch(expected: providerID, found: file.providerId)
        }
        return file.models.map { $0.toProviderCatalogEntry() }
    }
}

enum ProviderCatalogLoaderError: Error, Equatable, Sendable {
    case providerIDMismatch(expected: ProviderID, found: ProviderID)
}

enum ProviderCatalogStableID {
    static func registryUUID(providerID: ProviderID, endpointModelId: String) -> UUID {
        let input = "SwiftAgentHarness.ProviderCatalog|\(providerID)|\(endpointModelId)"
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

func bundledStaticCatalogEntries(providerID: ProviderID) -> [ProviderCatalogEntry] {
    (try? ProviderCatalogLoader.decodeBundledCatalog(for: providerID)) ?? []
}
