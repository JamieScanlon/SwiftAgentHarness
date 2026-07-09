import Foundation
import SwiftAgentKit

enum ToolRegistryResultFormattingPolicy {
    static let exactContentObservationTagRawValue = "exact-content-observation"
    static let compactionProtectedTagRawValue = "compaction-protected"

    static func exactContentObservationPolicyTag() -> ToolPolicyTag {
        ToolPolicyTag(rawValue: exactContentObservationTagRawValue)
    }

    static func compactionProtectedPolicyTag() -> ToolPolicyTag {
        ToolPolicyTag(rawValue: compactionProtectedTagRawValue)
    }

    static func skipsLossyContentTrim(
        entry: ToolRegistryEntry?,
        toolName: String,
        stage: ToolResultFormattingStage
    ) -> Bool {
        guard stage == .runtime || stage == .persistence else { return false }
        if let entry, entry.policyTags.contains(.exactContentObservation) {
            return true
        }
        return false
    }

    static func skipsMetadataTrim(
        entry: ToolRegistryEntry?,
        toolName: String,
        stage: ToolResultFormattingStage
    ) -> Bool {
        guard stage == .runtime || stage == .persistence else { return false }
        if let entry, entry.policyTags.contains(.exactContentObservation) {
            return true
        }
        return false
    }

    static func isCompactionProtected(entry: ToolRegistryEntry?, toolName: String) -> Bool {
        if let entry, entry.policyTags.contains(.compactionProtected) {
            return true
        }
        return isDelegateToolName(toolName)
    }

    static func isCompactionProtectedForPruning(
        toolName: String,
        configuredProtectedNames: Set<String> = []
    ) -> Bool {
        if configuredProtectedNames.contains(toolName) {
            return true
        }
        return isDelegateToolName(toolName)
    }

    static func compactionProtectedToolNames(from entries: [ToolRegistryEntry]) -> Set<String> {
        Set(
            entries
                .filter { $0.policyTags.contains(.compactionProtected) }
                .map(\.name)
        )
    }

    static func isDelegateTool(entry: ToolRegistryEntry) -> Bool {
        if entry.transportKind == .a2a || entry.source == .a2a { return true }
        if entry.definition.type == .a2aAgent { return true }
        if entry.transportKind == .acp { return true }
        if entry.definition.type == .acpAgent { return true }
        return isDelegateToolName(entry.name)
    }

    static func isDelegateToolName(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("delegate_")
    }

    static func isDelegateDescriptor(
        descriptor: RegisteredToolDescriptor,
        transportKind: ToolRegistryEntry.TransportKind,
        source: ToolListingSource
    ) -> Bool {
        if transportKind == .a2a || source == .a2a { return true }
        if descriptor.definition.type == .a2aAgent { return true }
        if transportKind == .acp { return true }
        if descriptor.definition.type == .acpAgent { return true }
        return isDelegateToolName(descriptor.definition.name)
    }
}
