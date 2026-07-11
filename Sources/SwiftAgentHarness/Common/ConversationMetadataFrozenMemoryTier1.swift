import EasyJSON
import Foundation

/// Session-frozen tier-1 memory slice in ``ModelConversation/metadata`` (stable prefix above cache boundary).
public enum ConversationMetadataFrozenMemoryTier1 {
    public static let workspaceInstructionSectionKey = "frozenMemoryWorkspaceInstructionSection"
    public static let tier1ContentKey = "frozenMemoryTier1Content"
    public static let snapshotGenerationKey = "frozenMemorySnapshotGeneration"
    public static let digestMetadataKey = "frozenMemoryTier1Digest"

    public struct FrozenSlice: Sendable, Equatable {
        public let workspaceInstructionSection: String
        public let tier1Content: String
        public let snapshotGeneration: Int

        public init(workspaceInstructionSection: String, tier1Content: String, snapshotGeneration: Int) {
            self.workspaceInstructionSection = workspaceInstructionSection
            self.tier1Content = tier1Content
            self.snapshotGeneration = snapshotGeneration
        }
    }

    public static func frozenSlice(from metadata: JSON?) -> FrozenSlice? {
        guard let metadata, case .object(let dict) = metadata else { return nil }
        guard let generationValue = dict[snapshotGenerationKey],
              case .double(let generationDouble) = generationValue else {
            return nil
        }
        let generation = Int(generationDouble)
        let workspace = stringValue(for: workspaceInstructionSectionKey, in: dict) ?? ""
        let tier1 = stringValue(for: tier1ContentKey, in: dict) ?? ""
        guard !workspace.isEmpty || !tier1.isEmpty else { return nil }
        return FrozenSlice(
            workspaceInstructionSection: workspace,
            tier1Content: tier1,
            snapshotGeneration: generation
        )
    }

    public static func mergingFrozenMemoryTier1(
        workspaceInstructionSection: String,
        tier1Content: String,
        snapshotGeneration: Int,
        into metadata: JSON?
    ) -> JSON? {
        var root: [String: JSON] = [:]
        if let metadata, case .object(let dict) = metadata {
            root = dict
        }
        root[workspaceInstructionSectionKey] = .string(workspaceInstructionSection)
        root[tier1ContentKey] = .string(tier1Content)
        root[snapshotGenerationKey] = .double(Double(snapshotGeneration))
        let digestPayload = [
            workspaceInstructionSection,
            tier1Content,
            String(snapshotGeneration),
        ].joined(separator: "\u{1f}")
        root[digestMetadataKey] = .string(SystemPromptDispatchCodec.sha256Digest(of: digestPayload))
        return .object(root)
    }

    public static func clearingFrozenMemoryTier1(from metadata: JSON?) -> JSON? {
        guard let metadata, case .object(var dict) = metadata else { return metadata }
        dict.removeValue(forKey: workspaceInstructionSectionKey)
        dict.removeValue(forKey: tier1ContentKey)
        dict.removeValue(forKey: snapshotGenerationKey)
        dict.removeValue(forKey: digestMetadataKey)
        return dict.isEmpty ? nil : .object(dict)
    }

    public static func mergingPreservingFrozenMemoryTier1(existing: JSON?, incoming: JSON) -> JSON {
        guard case .object(var incomingObject) = incoming else {
            return incoming
        }
        guard let existing, case .object(let existingObject) = existing else {
            return incoming
        }
        for key in [
            workspaceInstructionSectionKey,
            tier1ContentKey,
            snapshotGenerationKey,
            digestMetadataKey,
        ] {
            if incomingObject[key] == nil, let preserved = existingObject[key] {
                incomingObject[key] = preserved
            }
        }
        return .object(incomingObject)
    }

    static func memorySystemPromptBlocks(from frozen: FrozenSlice) -> MemorySystemPromptBlocks {
        MemorySystemPromptBlocks(
            projectInstructionsText: frozen.workspaceInstructionSection,
            memoryIndexText: frozen.tier1Content,
            recalledTopicBodiesText: "",
            taxonomyPromptText: "",
            driftGuardText: "",
            sensitiveDataPromptText: "",
            memoryPathDisclosureText: "",
            snapshotGeneration: frozen.snapshotGeneration
        )
    }

    private static func stringValue(for key: String, in dict: [String: JSON]) -> String? {
        guard let value = dict[key], case .string(let text) = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}
