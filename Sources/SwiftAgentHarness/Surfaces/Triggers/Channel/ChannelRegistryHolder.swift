import Foundation
import Synchronization

final class ChannelRegistryHolder: Sendable {
    private let state = Mutex<(any ChannelListenerLooking)?>(nil)

    var registry: (any ChannelListenerLooking)? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
