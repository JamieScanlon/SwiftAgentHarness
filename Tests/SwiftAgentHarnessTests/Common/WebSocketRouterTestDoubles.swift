import Foundation
import SwiftAgentKit
@testable import SwiftAgentHarness

final class SubscribeRouterModelManagerDouble: APILayerModelManaging, Sendable {
    private let models: [Model]

    init(models: [Model]) {
        self.models = models
    }

    func getAvailableModels() async -> [Model] { models }
}

enum WebSocketRouterTestFixtures {
    static func model(id: UUID) -> Model {
        Model(id: id, protocol: .openAIAPI, modelName: "fixture", serverURL: URL(string: "http://localhost")!)
    }
}
