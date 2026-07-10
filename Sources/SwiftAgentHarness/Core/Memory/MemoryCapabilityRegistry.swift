import Foundation

enum MemoryCapabilityRegistryError: Error, Equatable {
    case alreadyRegistered(incumbentID: String)
}

actor MemoryCapabilityRegistry {
    private var active: MemoryCapability

    init(defaultCapability: MemoryCapability) {
        self.active = defaultCapability
    }

    func activeCapability() -> MemoryCapability {
        active
    }

    func activePluginID() -> String {
        active.pluginID
    }

    func register(_ capability: MemoryCapability) throws {
        if capability.pluginID == active.pluginID {
            throw MemoryCapabilityRegistryError.alreadyRegistered(incumbentID: active.pluginID)
        }
        active = capability
    }

    func replaceActive(_ capability: MemoryCapability) {
        active = capability
    }

    func shutdownActive() async {
        await active.runtime.shutdown()
    }

    func endSessionActive(conversationID: UUID) async {
        await active.runtime.endSession(conversationID: conversationID)
    }
}
