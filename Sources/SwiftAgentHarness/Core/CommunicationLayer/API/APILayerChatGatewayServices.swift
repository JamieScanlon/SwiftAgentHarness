import Foundation

/// bundles protocol projections for REST/WebSocket dependency injection.
///
/// Tests may still use ``init(unified:)`` so one fake implements both protocols.
struct APILayerChatGatewayServices: Sendable {
    let conversation: APILayerConversationManaging
    let runtime: APILayerChatRuntimeManaging

    init(unified chat: APILayerChatManaging) {
        self.conversation = chat
        self.runtime = chat
    }

    init(conversation: APILayerConversationManaging, runtime: APILayerChatRuntimeManaging) {
        self.conversation = conversation
        self.runtime = runtime
    }
}
