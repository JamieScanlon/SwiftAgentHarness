import Foundation
import Synchronization

/// The outcome of a channel lifecycle mutation.
///
/// `appliedToRunningProcess` is the honest half. Persisting the decision and applying it are two
/// steps, and a client that reports "paused" when only the first happened has told the user the
/// channel stopped listening when it did not.
struct ChannelLifecycleResult: Sendable, Equatable {
    var entry: ChannelRuntimeStateEntry
    var appliedToRunningProcess: Bool

    var summary: String {
        let verb = entry.disabled ? "paused" : "resumed"
        guard appliedToRunningProcess else {
            return "\(verb) channel=\(entry.channel) (recorded; takes effect at next start — no live listener registry is attached)"
        }
        return "\(verb) channel=\(entry.channel)"
    }
}

/// Late-bound bridge from the registration endpoint to the live listener registry.
///
/// The registry is constructed *after* the registration service — it depends on the dispatch chain
/// the registration service also feeds — so the edge can only be closed once both exist. Same shape
/// and same reason as `TriggerBudgetNotifierHolder`.
///
/// `Mutex` rather than `NSLock`: this is read from `async` context, which is the axis this codebase
/// picks its locking idiom on.
final class ChannelLifecycleApplierHolder: Sendable {
    private let applier = Mutex<(@Sendable () async -> Void)?>(nil)

    init() {}

    func install(_ apply: @escaping @Sendable () async -> Void) {
        applier.withLock { $0 = apply }
    }

    /// Apply the persisted overlay to the running process.
    ///
    /// - Returns: `false` when no registry is attached, so the caller can say "recorded, not applied"
    ///   instead of implying the listener stopped.
    func applyChannelState() async -> Bool {
        guard let apply = applier.withLock({ $0 }) else { return false }
        await apply()
        return true
    }
}
