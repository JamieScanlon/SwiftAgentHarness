import Foundation

/// Process-environment accessor with a task-scoped override seam.
///
/// Production reads resolve from `ProcessInfo.processInfo.environment`. Tests (and any caller that
/// needs deterministic, isolated configuration) can supply overrides via
/// ``$overrides`` / `HarnessEnvironmentOverride.$overrides.withValue(_:)`. Because the override is a
/// task-local, it is scoped to the current task tree only and is invisible to other concurrently
/// running tasks — unlike `setenv`, it cannot leak into tests running in parallel.
enum HarnessEnvironmentOverride {
    /// Task-scoped environment overrides; checked before the real process environment.
    @TaskLocal static var overrides: [String: String]?

    /// Resolves `key` from the task-local override (when present) before falling back to the process
    /// environment.
    static func string(_ key: String) -> String? {
        if let overrides, let value = overrides[key] {
            return value
        }
        return ProcessInfo.processInfo.environment[key]
    }
}
