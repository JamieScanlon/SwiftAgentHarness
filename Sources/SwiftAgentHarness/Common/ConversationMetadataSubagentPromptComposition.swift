import EasyJSON
import Foundation

public enum ConversationMetadataSubagentPromptComposition {
    public static let modeKey = "promptCompositionMode"
    public static let inheritedParentPromptDigestKey = "inheritedParentPromptDigest"
    public static let inheritedParentConversationIDKey = "inheritedParentConversationID"
    public static let inheritedReplaySpecDigestKey = "inheritedReplaySpecDigest"
    public static let inheritedAssembledPromptTextKey = "inheritedAssembledPromptText"
    public static let spawnTaskDirectiveKey = "spawnTaskDirective"

    public static func promptCompositionMode(from metadata: JSON?) -> SubagentPromptCompositionMode? {
        guard let metadata, case .object(let dict) = metadata,
              let value = dict[modeKey],
              case .string(let raw) = value else {
            return nil
        }
        return SubagentPromptCompositionMode(rawValue: raw)
    }

    public static func inheritedAssembledPromptText(from metadata: JSON?) -> String? {
        guard let metadata, case .object(let dict) = metadata,
              let value = dict[inheritedAssembledPromptTextKey],
              case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    public static func inheritedParentPromptDigest(from metadata: JSON?) -> String? {
        stringMetadataValue(for: inheritedParentPromptDigestKey, in: metadata)
    }

    public static func inheritedParentConversationID(from metadata: JSON?) -> UUID? {
        guard let raw = stringMetadataValue(for: inheritedParentConversationIDKey, in: metadata) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    public static func inheritedReplaySpecDigest(from metadata: JSON?) -> String? {
        stringMetadataValue(for: inheritedReplaySpecDigestKey, in: metadata)
    }

    public static func spawnTaskDirective(from metadata: JSON?) -> String? {
        stringMetadataValue(for: spawnTaskDirectiveKey, in: metadata)
    }

    public static func mergingForkInheritance(
        parentConversationID: UUID,
        assembledPromptText: String,
        assembledPromptDigest: String,
        replaySpecDigest: String?,
        into metadata: JSON?
    ) -> JSON? {
        var root = metadataObject(from: metadata)
        root[modeKey] = .string(SubagentPromptCompositionMode.fork.rawValue)
        root[inheritedParentConversationIDKey] = .string(parentConversationID.uuidString)
        root[inheritedParentPromptDigestKey] = .string(assembledPromptDigest)
        root[inheritedAssembledPromptTextKey] = .string(assembledPromptText)
        if let replaySpecDigest {
            root[inheritedReplaySpecDigestKey] = .string(replaySpecDigest)
        }
        root.removeValue(forKey: spawnTaskDirectiveKey)
        return .object(root)
    }

    public static func mergingSpawnComposition(
        taskDirective: String?,
        into metadata: JSON?
    ) -> JSON? {
        var root = metadataObject(from: metadata)
        root[modeKey] = .string(SubagentPromptCompositionMode.spawn.rawValue)
        root.removeValue(forKey: inheritedParentConversationIDKey)
        root.removeValue(forKey: inheritedParentPromptDigestKey)
        root.removeValue(forKey: inheritedAssembledPromptTextKey)
        root.removeValue(forKey: inheritedReplaySpecDigestKey)
        if let taskDirective = taskDirective?.trimmingCharacters(in: .whitespacesAndNewlines), !taskDirective.isEmpty {
            root[spawnTaskDirectiveKey] = .string(taskDirective)
        } else {
            root.removeValue(forKey: spawnTaskDirectiveKey)
        }
        return .object(root)
    }

    public static func mergingPreservingCompositionMetadata(existing: JSON?, incoming: JSON) -> JSON {
        guard case .object(var incomingObject) = incoming else {
            return incoming
        }
        guard let existing, case .object(let existingObject) = existing else {
            return incoming
        }
        for key in [
            modeKey,
            inheritedParentConversationIDKey,
            inheritedParentPromptDigestKey,
            inheritedAssembledPromptTextKey,
            inheritedReplaySpecDigestKey,
            spawnTaskDirectiveKey,
        ] {
            if incomingObject[key] == nil, let preserved = existingObject[key] {
                incomingObject[key] = preserved
            }
        }
        return .object(incomingObject)
    }

    private static func metadataObject(from metadata: JSON?) -> [String: JSON] {
        if let metadata, case .object(let dict) = metadata {
            return dict
        }
        return [:]
    }

    private static func stringMetadataValue(for key: String, in metadata: JSON?) -> String? {
        guard let metadata, case .object(let dict) = metadata,
              let value = dict[key],
              case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}
