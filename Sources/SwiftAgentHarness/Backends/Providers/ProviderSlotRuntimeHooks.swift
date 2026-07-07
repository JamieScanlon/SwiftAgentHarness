import Foundation

/// Dispatch seam for non-text provider capability slots (spec: parallel registration).
public enum ProviderSlotRuntimeHooks {
    public static func cliInferenceBackend(
        providerID: ProviderID,
        cliBackendID: String
    ) throws -> any CLIInferenceBackendProviding {
        try ProviderRegistry.cliInferenceBackend(providerID: providerID, cliBackendID: cliBackendID)
    }

    public static func provider(
        for slot: ProviderCapabilitySlot,
        providerID: ProviderID
    ) throws -> (any Sendable)? {
        try ProviderRegistry.provider(for: slot, providerID: providerID)
    }
}
