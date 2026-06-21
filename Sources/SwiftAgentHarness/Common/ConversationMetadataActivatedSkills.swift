import Foundation
import EasyJSON

/// Helpers for the `activatedAgentSkillNames` entry in ``ModelConversation/metadata`` (mirrors `CachedConversation.metadataJSON`).
public enum ConversationMetadataActivatedSkills {
    public static let metadataKey = "activatedAgentSkillNames"

    /// Reads persisted activated skill directory names from conversation metadata.
    public static func activatedAgentSkillNames(from metadata: JSON?) -> [String] {
        guard let metadata, case .object(let dict) = metadata,
              let value = dict[metadataKey] else {
            return []
        }
        guard case .array(let elements) = value else {
            return []
        }
        return elements.compactMap { element in
            if case .string(let s) = element { return s }
            return nil
        }
    }

    /// Merges `names` into the root metadata object under ``metadataKey`` (sorted for stable persistence).
    public static func mergingActivatedAgentSkillNames(_ names: Set<String>, into metadata: JSON?) -> JSON? {
        var root: [String: JSON] = [:]
        if let metadata, case .object(let dict) = metadata {
            root = dict
        }
        root[metadataKey] = .array(names.sorted().map { .string($0) })
        return .object(root)
    }

    /// When replacing metadata via API, preserve ``metadataKey`` from `existing` if `incoming` omits it.
    public static func mergingPreservingActivatedSkillNames(existing: JSON?, incoming: JSON) -> JSON {
        guard case .object(var incomingObject) = incoming else {
            return incoming
        }
        if incomingObject[metadataKey] != nil {
            return incoming
        }
        guard let existing, case .object(let existingObject) = existing,
              let preserved = existingObject[metadataKey] else {
            return incoming
        }
        incomingObject[metadataKey] = preserved
        return .object(incomingObject)
    }
}
