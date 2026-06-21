import Foundation
import Logging
import Vapor

struct APILayerWebSocketDependencies: Sendable {
    let conversation: APILayerConversationManaging
    let runtime: APILayerChatRuntimeManaging
    let modelManager: APILayerModelManaging
    let logger: Logger
    let tenancyPolicy: TenancyPolicySettings

    init(
        gateway: APILayerChatGatewayServices,
        modelManager: APILayerModelManaging,
        logger: Logger,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.conversation = gateway.conversation
        self.runtime = gateway.runtime
        self.modelManager = modelManager
        self.logger = logger
        self.tenancyPolicy = tenancyPolicy
    }

    init(
        chatManaging unified: APILayerChatManaging,
        modelManager: APILayerModelManaging,
        logger: Logger,
        tenancyPolicy: TenancyPolicySettings = .disabled
    ) {
        self.init(
            gateway: APILayerChatGatewayServices(unified: unified),
            modelManager: modelManager,
            logger: logger,
            tenancyPolicy: tenancyPolicy
        )
    }
}
