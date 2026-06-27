import Foundation
import Synchronization

/// Late-bound slot for ``ChannelSessionLifecycleCoordinator`` so runtime cancel paths can drain channel session tasks.
public final class ChannelSessionLifecycleCoordinatorHolder: Sendable {
    private let state = Mutex<ChannelSessionLifecycleCoordinator?>(nil)

    public func install(_ coordinator: ChannelSessionLifecycleCoordinator) {
        state.withLock { $0 = coordinator }
    }

    func coordinator() -> ChannelSessionLifecycleCoordinator? {
        state.withLock { $0 }
    }
}
