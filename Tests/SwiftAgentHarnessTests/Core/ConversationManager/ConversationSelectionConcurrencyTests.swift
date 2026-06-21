import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite struct ConversationSelectionConcurrencyTests {

    @Test("parallel selection reads and selectConversation complete through port")
    func parallelSelectionAccess() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "selection-concurrency")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = Model(
            protocol: .ollama,
            modelName: "test:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [],
            modelProtocol: .ollama
        )
        let (conversationID, secondID) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: fixture.host,
            model: model
        )
        let selection = fixture.services.selection

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    for _ in 0..<10 {
                        if index.isMultiple(of: 2) {
                            _ = await selection.currentConversationID()
                            _ = await selection.currentConversation()
                        } else {
                            let target = index.isMultiple(of: 3) ? conversationID : secondID
                            try? await selection.selectConversation(conversationID: target)
                        }
                    }
                }
            }
            await group.waitForAll()
        }

        let selected = await selection.currentConversationID()
        #expect(selected == conversationID || selected == secondID)
    }
}
