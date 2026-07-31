import Foundation
import Synchronization

/// Late-bound notifier for breach notices.
///
/// The budget gate is constructed before the output router (the router needs the dispatch service,
/// which needs the activation policy, which needs the gate), so the notifier is installed after the
/// fact — the same shape as `ChannelRegistryHolder` and `ChannelRunStreamingServiceHolder`.
public final class TriggerBudgetNotifierHolder: Sendable {
    private let state = Mutex<(@Sendable (TriggerBudgetBreachNotice) async -> Void)?>(nil)

    public init() {}

    func install(_ notifier: @escaping @Sendable (TriggerBudgetBreachNotice) async -> Void) {
        state.withLock { $0 = notifier }
    }

    func notify(_ notice: TriggerBudgetBreachNotice) async {
        let current = state.withLock { $0 }
        await current?(notice)
    }
}
