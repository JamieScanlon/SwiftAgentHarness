import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor RecordingDispatchAccounting: BudgetAccounting {
    enum Event: Equatable, Sendable {
        case authorize(modelID: UUID, conversationID: UUID?, accountID: UUID?, projectedCostUSD: Double?)
        case recordCompletion(modelID: UUID, conversationID: UUID?, accountID: UUID?, actualCostUSD: Double?)
    }

    private(set) var events: [Event] = []
    private let throwOnAuthorize: Error?

    init(throwOnAuthorize: Error? = nil) {
        self.throwOnAuthorize = throwOnAuthorize
    }

    func authorize(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        projectedCostUSD: Double?
    ) async throws {
        events.append(.authorize(modelID: modelID, conversationID: conversationID, accountID: accountID, projectedCostUSD: projectedCostUSD))
        if let throwOnAuthorize { throw throwOnAuthorize }
    }

    func recordCompletion(
        policy: BudgetPolicy,
        modelID: UUID,
        conversationID: UUID?,
        accountID: UUID?,
        actualCostUSD: Double?
    ) async {
        events.append(.recordCompletion(modelID: modelID, conversationID: conversationID, accountID: accountID, actualCostUSD: actualCostUSD))
    }

    func observed() -> [Event] { events }
}

@Suite("ModelPoolBudgetDispatch facades")
struct ModelPoolBudgetDispatchTests {
    @Test("authorize routes the call through the injected accounting")
    func authorizeRoutes() async throws {
        let accounting = RecordingDispatchAccounting()
        let modelID = UUID()
        let conversationID = UUID()

        try await ModelPoolBudgetDispatch.authorize(
            accounting: accounting,
            policy: .enabled(maxUSDPerCall: 0.05, maxUSDPerConversation: nil),
            modelID: modelID,
            conversationID: conversationID,
            accountID: nil,
            projectedCostUSD: 0.01
        )

        let events = await accounting.observed()
        #expect(events.count == 1)
        #expect(events.first == .authorize(
            modelID: modelID,
            conversationID: conversationID,
            accountID: nil,
            projectedCostUSD: 0.01
        ))
    }

    @Test("authorize rethrows whatever the accounting throws")
    func authorizeRethrows() async throws {
        let accounting = RecordingDispatchAccounting(throwOnAuthorize: LLMError.quotaExceeded)

        await #expect(throws: LLMError.self) {
            try await ModelPoolBudgetDispatch.authorize(
                accounting: accounting,
                policy: .disabled,
                modelID: UUID(),
                conversationID: nil,
                accountID: nil,
                projectedCostUSD: nil
            )
        }
    }

    @Test("settle routes the call through the injected accounting")
    func settleRoutes() async throws {
        let accounting = RecordingDispatchAccounting()
        let modelID = UUID()

        await ModelPoolBudgetDispatch.settle(
            accounting: accounting,
            policy: .disabled,
            modelID: modelID,
            conversationID: nil,
            accountID: nil,
            actualCostUSD: 0.42
        )

        let events = await accounting.observed()
        #expect(events.count == 1)
        #expect(events.first == .recordCompletion(
            modelID: modelID,
            conversationID: nil,
            accountID: nil,
            actualCostUSD: 0.42
        ))
    }

    @Test("authorize/settle preserve non-nil accountID")
    func accountIDIsForwarded() async throws {
        let accounting = RecordingDispatchAccounting()
        let modelID = UUID()
        let conversationID = UUID()
        let accountID = UUID()
        try await ModelPoolBudgetDispatch.authorize(
            accounting: accounting,
            policy: .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil),
            modelID: modelID,
            conversationID: conversationID,
            accountID: accountID,
            projectedCostUSD: 0.01
        )
        await ModelPoolBudgetDispatch.settle(
            accounting: accounting,
            policy: .enabled(maxUSDPerCall: nil, maxUSDPerConversation: nil),
            modelID: modelID,
            conversationID: conversationID,
            accountID: accountID,
            actualCostUSD: 0.01
        )
        let events = await accounting.observed()
        #expect(events.count == 2)
        #expect(events[0] == .authorize(modelID: modelID, conversationID: conversationID, accountID: accountID, projectedCostUSD: 0.01))
        #expect(events[1] == .recordCompletion(modelID: modelID, conversationID: conversationID, accountID: accountID, actualCostUSD: 0.01))
    }
}
