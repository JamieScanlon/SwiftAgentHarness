//
//  Catalog `resource_json` column: harness resource fields (tags, routing, budget, branches, attachments, metadata).
//

import EasyJSON
import Foundation
import SwiftAgentKit

struct SessionCatalogResourcePayload: Codable, Equatable, Sendable {
    var extraInstructions: String?
    var systemPromptFullOverride: Bool?
    var tags: [String]?
    var routingPrefs: ConversationRoutingPrefs?
    var budgetSnapshot: ConversationBudgetSnapshot?
    var branchChildren: [ConversationBranchRef]?
    var attachmentsCatalog: [ConversationAttachmentDescriptor]?
    var metadataJSON: String?
    var systemPrompt: String?
}

enum SessionCatalogResourceCodec {
    static func encode(_ conversation: ModelConversation) -> String? {
        let payload = payload(from: conversation)
        guard !payload.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> SessionCatalogResourcePayload? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionCatalogResourcePayload.self, from: data)
    }

    static func payload(from conversation: ModelConversation) -> SessionCatalogResourcePayload {
        SessionCatalogResourcePayload(
            extraInstructions: conversation.extraInstructions,
            systemPromptFullOverride: conversation.systemPromptFullOverride ? true : nil,
            tags: conversation.tags.isEmpty ? nil : conversation.tags,
            routingPrefs: conversation.routingPrefs,
            budgetSnapshot: conversation.budgetSnapshot,
            branchChildren: conversation.branchChildren.isEmpty ? nil : conversation.branchChildren,
            attachmentsCatalog: conversation.attachmentsCatalog.isEmpty ? nil : conversation.attachmentsCatalog,
            metadataJSON: encodeConversationMetadataJSON(conversation.metadata),
            systemPrompt: conversation.systemPrompt.isEmpty ? nil : conversation.systemPrompt
        )
    }

    static func hydrateResourceFields(from record: SessionCatalogRecord, into model: inout ModelConversation) {
        if let raw = record.resourceRunStatusRaw,
           let status = ConversationResourceRunStatus(rawValue: raw) {
            model.resourceRunStatus = status
        }
        model.currentRunID = record.currentRunID
        model.lastActiveAt = record.lastActiveAt ?? model.updatedAt
        if let prompt = record.systemPrompt, !prompt.isEmpty {
            model.systemPrompt = prompt
        }
        if let metadataJSON = record.metadataJSON,
           let data = metadataJSON.data(using: .utf8),
           let metadata = try? JSONDecoder().decode(JSON.self, from: data) {
            model.metadata = metadata
        }
        guard let payload = decode(record.resourceJSON) else { return }
        model.extraInstructions = payload.extraInstructions
        model.systemPromptFullOverride = payload.systemPromptFullOverride ?? false
        if let tags = payload.tags { model.tags = tags }
        if let prefs = payload.routingPrefs { model.routingPrefs = prefs }
        if let budget = payload.budgetSnapshot { model.budgetSnapshot = budget }
        if let branches = payload.branchChildren { model.branchChildren = branches }
        if let attachments = payload.attachmentsCatalog { model.attachmentsCatalog = attachments }
        if let metadataJSON = payload.metadataJSON,
           let data = metadataJSON.data(using: .utf8),
           let metadata = try? JSONDecoder().decode(JSON.self, from: data) {
            model.metadata = metadata
        }
        if let prompt = payload.systemPrompt, !prompt.isEmpty {
            model.systemPrompt = prompt
        }
    }

    static func modelConfigJSONHint(from conversation: ModelConversation) -> String? {
        struct Hint: Codable {
            var thinkingConfig: ThinkingConfig
        }
        let thinkingConfig: ThinkingConfig = {
            if let configured = conversation.routingPrefs?.modelOptions?.thinkingConfig {
                return configured
            }
            return conversation.model.capabilities.hasReasoningCapability ? .adaptive : .disabled
        }()
        let hint = Hint(thinkingConfig: thinkingConfig)
        guard let data = try? JSONEncoder().encode(hint) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeConversationMetadataJSON(_ metadata: JSON?) -> String? {
        guard let metadata else { return nil }
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension SessionCatalogResourcePayload {
    var isEmpty: Bool {
        extraInstructions == nil
            && systemPromptFullOverride == nil
            && tags == nil
            && routingPrefs == nil
            && budgetSnapshot == nil
            && branchChildren == nil
            && attachmentsCatalog == nil
            && metadataJSON == nil
            && systemPrompt == nil
    }
}
