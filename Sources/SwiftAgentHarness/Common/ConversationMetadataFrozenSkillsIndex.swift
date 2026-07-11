import EasyJSON
import Foundation

/// Session-frozen skills index XML in ``ModelConversation/metadata`` (stable prefix above cache boundary).
public enum ConversationMetadataFrozenSkillsIndex {
    public static let metadataKey = "frozenSkillsIndexXML"
    public static let digestMetadataKey = "frozenSkillsIndexDigest"

    public static func frozenSkillsIndexXML(from metadata: JSON?) -> String? {
        guard let metadata, case .object(let dict) = metadata,
              let value = dict[metadataKey],
              case .string(let xml) = value else {
            return nil
        }
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : xml
    }

    public static func frozenSkillsIndexDigest(from metadata: JSON?) -> String? {
        guard let metadata, case .object(let dict) = metadata,
              let value = dict[digestMetadataKey],
              case .string(let digest) = value else {
            return nil
        }
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : digest
    }

    public static func mergingFrozenSkillsIndex(xml: String, into metadata: JSON?) -> JSON? {
        var root: [String: JSON] = [:]
        if let metadata, case .object(let dict) = metadata {
            root = dict
        }
        root[metadataKey] = .string(xml)
        root[digestMetadataKey] = .string(SystemPromptDispatchCodec.sha256Digest(of: xml))
        return .object(root)
    }

    public static func mergingPreservingFrozenSkillsIndex(existing: JSON?, incoming: JSON) -> JSON {
        guard case .object(var incomingObject) = incoming else {
            return incoming
        }
        guard let existing, case .object(let existingObject) = existing else {
            return incoming
        }
        if incomingObject[metadataKey] == nil, let preserved = existingObject[metadataKey] {
            incomingObject[metadataKey] = preserved
        }
        if incomingObject[digestMetadataKey] == nil, let preserved = existingObject[digestMetadataKey] {
            incomingObject[digestMetadataKey] = preserved
        }
        return .object(incomingObject)
    }
}
