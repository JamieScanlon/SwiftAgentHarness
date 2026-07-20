import Foundation

/// Well-known ``ModelRegistryEntry/useClasses`` tokens used by pool ranking.
public enum ModelUseClass: Sendable {
    /// Cheap tools-capable models preferred for active-memory recall (and related memory LLM paths).
    public static let memoryRecall = "memory-recall"
}
