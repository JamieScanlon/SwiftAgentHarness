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

struct BundledCatalogSystemPromptContribution: Codable, Sendable {
    var stablePrefix: String?
    var sectionOverrides: [String: String]?

    func toProviderSystemPromptContribution() -> ProviderSystemPromptContribution? {
        var overrides: [ProviderNamedSection: String] = [:]
        for (key, value) in sectionOverrides ?? [:] {
            guard let section = ProviderNamedSection(rawValue: key) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            overrides[section] = trimmed
        }
        let prefix = stablePrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard prefix != nil || !overrides.isEmpty else { return nil }
        return ProviderSystemPromptContribution(stablePrefix: prefix, sectionOverrides: overrides)
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
    var systemPromptContribution: BundledCatalogSystemPromptContribution?

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

struct BundledCatalogOverrideModel: Codable, Sendable {
    var modelFamily: String?
    var systemPromptContribution: BundledCatalogSystemPromptContribution?
}

struct BundledProviderOverridesFile: Codable, Sendable {
    var providerId: String
    var models: [String: BundledCatalogOverrideModel]?
    var modelFamilies: [String: BundledCatalogOverrideModel]?
}

enum ProviderCatalogLoader {
    static func bundledCatalogData(for providerID: ProviderID) -> Data? {
        let candidates = [
            ProviderResourceBundle.resourceBundle.url(
                forResource: providerID,
                withExtension: "catalog.json",
                subdirectory: "catalogs"
            ),
            ProviderResourceBundle.resourceBundle.url(
                forResource: providerID,
                withExtension: "catalog.json"
            ),
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
        try decodeBundledCatalogFile(for: providerID).models.map { $0.toProviderCatalogEntry() }
    }

    static func decodeBundledCatalogFile(for providerID: ProviderID) throws -> BundledProviderCatalogFile {
        guard let data = bundledCatalogData(for: providerID) else {
            return BundledProviderCatalogFile(providerId: providerID, generatedAt: nil, models: [])
        }
        let file = try JSONDecoder().decode(BundledProviderCatalogFile.self, from: data)
        guard file.providerId == providerID else {
            throw ProviderCatalogLoaderError.providerIDMismatch(expected: providerID, found: file.providerId)
        }
        return file
    }

    static func catalogModelRow(for binding: ProviderBinding) -> BundledCatalogModelRow? {
        guard let file = try? decodeBundledCatalogFile(for: binding.providerId) else { return nil }
        return file.models.first(where: { $0.endpointModelId == binding.endpointModelId })
    }

    static func decodeBundledOverrides(for providerID: ProviderID) -> BundledProviderOverridesFile? {
        guard let data = bundledOverridesData(for: providerID) else { return nil }
        return try? JSONDecoder().decode(BundledProviderOverridesFile.self, from: data)
    }

    static func systemPromptContribution(for binding: ProviderBinding) -> ProviderSystemPromptContribution? {
        if let row = catalogModelRow(for: binding),
           let contribution = row.systemPromptContribution?.toProviderSystemPromptContribution() {
            return contribution
        }
        guard let overrides = decodeBundledOverrides(for: binding.providerId) else { return nil }
        if let modelOverlay = overrides.models?[binding.endpointModelId],
           let contribution = modelOverlay.systemPromptContribution?.toProviderSystemPromptContribution() {
            return contribution
        }
        let family = catalogModelRow(for: binding)?.modelFamily
            ?? overrides.models?[binding.endpointModelId]?.modelFamily
        guard let family,
              let familyOverlay = overrides.modelFamilies?[family],
              let contribution = familyOverlay.systemPromptContribution?.toProviderSystemPromptContribution() else {
            return nil
        }
        return contribution
    }

    private static func bundledOverridesData(for providerID: ProviderID) -> Data? {
        let candidates = [
            ProviderResourceBundle.resourceBundle.url(
                forResource: providerID,
                withExtension: "overrides.json"
            ),
            ProviderResourceBundle.resourceBundle.url(
                forResource: providerID,
                withExtension: "overrides.json",
                subdirectory: "catalogs/overrides"
            ),
            ProviderResourceBundle.resourceBundle.url(
                forResource: providerID,
                withExtension: "overrides.json",
                subdirectory: "overrides"
            ),
            Bundle.module.url(
                forResource: providerID,
                withExtension: "overrides.json"
            ),
            Bundle.module.url(
                forResource: providerID,
                withExtension: "overrides.json",
                subdirectory: "catalogs/overrides"
            ),
            Bundle.module.url(
                forResource: providerID,
                withExtension: "overrides.json",
                subdirectory: "overrides"
            ),
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return nil }
        return try? Data(contentsOf: url)
    }
}

enum ProviderCatalogLoaderError: Error, Equatable, Sendable {
    case providerIDMismatch(expected: ProviderID, found: ProviderID)
}

public enum ProviderCatalogStableID {
    public static func registryUUID(providerID: ProviderID, endpointModelId: String) -> UUID {
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

public func bundledStaticCatalogEntries(providerID: ProviderID) -> [ProviderCatalogEntry] {
    (try? ProviderCatalogLoader.decodeBundledCatalog(for: providerID)) ?? []
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
