import Foundation
import SwiftAgentKitACP

actor SubAgentPoolACPManagerProvider {
    private var manager: ACPManager?
    private var delegateBoxesByAgentName: [String: SubAgentACPClientDelegateBox] = [:]
    private var delegateFactory: (any SubAgentACPClientDelegateMaking)?

    func setBootstrap(
        manager: ACPManager?,
        delegateBoxes: [String: SubAgentACPClientDelegateBox] = [:]
    ) {
        self.manager = manager
        self.delegateBoxesByAgentName = delegateBoxes
    }

    func setDelegateFactory(_ factory: (any SubAgentACPClientDelegateMaking)?) {
        delegateFactory = factory
    }

    func currentManager() -> ACPManager? {
        manager
    }

    func delegateBox(forAgentName name: String) -> SubAgentACPClientDelegateBox? {
        delegateBoxesByAgentName[name]
    }

    func makeHarnessDelegate(
        request: SubAgentTransportInvocationRequest,
        lifecycleID: String
    ) async -> any ACPClientDelegate {
        guard let delegateFactory else {
            return DefaultACPClientDelegate(autoApprovePermissions: false)
        }
        return await delegateFactory.makeDelegate(request: request, lifecycleID: lifecycleID)
    }
}

protocol SubAgentACPClientDelegateMaking: Sendable {
    func makeDelegate(
        request: SubAgentTransportInvocationRequest,
        lifecycleID: String
    ) async -> any ACPClientDelegate
}
