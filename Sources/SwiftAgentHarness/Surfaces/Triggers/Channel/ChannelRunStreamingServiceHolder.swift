import Foundation
import Synchronization

/// Late-bound slot for ``ChannelRunStreamingService`` so trigger dispatch can be wired before the channel registry exists.
final class ChannelRunStreamingServiceHolder: Sendable {
    private let state = Mutex<ChannelRunStreamingService?>(nil)

    func install(_ service: ChannelRunStreamingService) {
        state.withLock { $0 = service }
    }

    func service() -> ChannelRunStreamingService? {
        state.withLock { $0 }
    }
}
