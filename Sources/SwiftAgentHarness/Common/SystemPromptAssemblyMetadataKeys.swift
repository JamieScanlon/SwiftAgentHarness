import Foundation

/// Metadata keys for CE → system prompt assembly (SP1 / MI2).
enum SystemPromptAssemblyMetadataKeys {
    static let tier1MemoryContent = "contextEngineTier1MemoryContent"
    static let memorySnapshotGeneration = "contextEngineMemorySnapshotGeneration"
    static let providerStablePrefix = "providerStablePrefix"
    static let assembledPromptDigest = "assembledPromptDigest"
    /// ISO-8601 instant frozen at CE assemble time; used for the `datetime` token instead of live `Date()`.
    static let assembleReferenceDateISO = "assembleReferenceDateISO"
}
