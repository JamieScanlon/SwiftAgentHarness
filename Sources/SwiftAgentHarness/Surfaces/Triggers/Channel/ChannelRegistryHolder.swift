import Foundation

final class ChannelRegistryHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _registry: (any ChannelListenerLooking)?

    var registry: (any ChannelListenerLooking)? {
        get { lock.withLock { _registry } }
        set { lock.withLock { _registry = newValue } }
    }
}
