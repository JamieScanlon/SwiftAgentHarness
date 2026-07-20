import Foundation
import Logging
import SwiftAgentKit

/// Resolves the model for active-memory recall via Model Pool policy (not a bespoke chain).
///
/// Order: optional pin (tools required) → trust-scoped `memory-recall` query → parent session
/// (tools required) → `nil` (skip recall). Never throws into the turn.
enum ActiveMemoryModelResolver: Sendable {
    static func resolve(
        parentModel: Model,
        config: MemoryConfiguration,
        ranked: @Sendable (ModelReference) async -> [ModelRegistryEntry],
        logger: Logger? = nil
    ) async -> Model? {
        if let pin = await resolvePin(config: config, ranked: ranked, logger: logger) {
            return pin
        }
        if let fromQuery = await resolveQuery(parentModel: parentModel, config: config, ranked: ranked) {
            return fromQuery
        }
        if parentModel.capabilities.contains(.tools) {
            return parentModel
        }
        logger?.debug("[ActiveMemory] no tools-capable model resolved; skipping recall")
        return nil
    }

    /// Protocols allowed under the session's trust tier (never upgrade trust by default).
    static func allowedProtocols(forSessionProtocol session: ModelProtocol) -> Set<ModelProtocol> {
        switch session {
        case .ollama, .lmStudio:
            return [.ollama, .lmStudio]
        case .openAIAPI, .anthropic:
            return [session]
        }
    }

    static func memoryRecallQuery(
        parentModel: Model,
        allowCrossProviderTrust: Bool
    ) -> ModelQuery {
        var query = ModelQuery(
            mustIncludeCapabilities: [.completion, .tools],
            preferredUseClass: ModelUseClass.memoryRecall
        )
        if !allowCrossProviderTrust {
            query.allowedModelProtocols = allowedProtocols(forSessionProtocol: parentModel.modelProtocol)
        }
        return query
    }

    private static func resolvePin(
        config: MemoryConfiguration,
        ranked: @Sendable (ModelReference) async -> [ModelRegistryEntry],
        logger: Logger?
    ) async -> Model? {
        guard let raw = config.activeMemoryModelRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let ref = ModelReference.parse(raw) else {
            return nil
        }
        let entries = await ranked(ref)
        guard let entry = entries.first else {
            logger?.debug("[ActiveMemory] pin \(raw) unresolved; falling through")
            return nil
        }
        guard entry.capabilities.contains(.tools) else {
            logger?.debug("[ActiveMemory] pin \(raw) lacks .tools; falling through")
            return nil
        }
        return entry.toModel()
    }

    private static func resolveQuery(
        parentModel: Model,
        config: MemoryConfiguration,
        ranked: @Sendable (ModelReference) async -> [ModelRegistryEntry]
    ) async -> Model? {
        let query = memoryRecallQuery(
            parentModel: parentModel,
            allowCrossProviderTrust: config.activeMemoryAllowCrossProviderTrust
        )
        let entries = await ranked(.query(query))
        return entries.first?.toModel()
    }
}
