import Foundation
import Synchronization

public final class ChannelRegistryHolder: Sendable {
    private let state = Mutex<(any ChannelListenerLooking)?>(nil)

    public var registry: ChannelListenerRegistry? {
        get { state.withLock { $0 as? ChannelListenerRegistry } }
        set { state.withLock { $0 = newValue } }
    }

    func assign(_ registry: any ChannelListenerLooking) {
        state.withLock { $0 = registry }
    }
}
