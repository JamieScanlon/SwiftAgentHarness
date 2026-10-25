import Foundation
import Testing
@testable import SwiftAgentHarness

actor RecordingIntentPublisher {
    private(set) var published: [(UUID, ClientSurfaceIntent)] = []

    func publish(_ conversationID: UUID, _ intent: ClientSurfaceIntent) {
        published.append((conversationID, intent))
    }

    var kinds: [ClientSurfaceIntent.Kind] { published.map(\.1.kind) }

    func firstRequestID() -> String? {
        published.first { $0.1.kind == .computerUseRequest }?.1.computerUse?.requestID
    }
}

actor CoordinatorBox {
    private(set) var value: ComputerUseOversightCoordinator?
    func set(_ coordinator: ComputerUseOversightCoordinator) { value = coordinator }
}

@Suite("Computer use oversight coordinator")
struct ComputerUseOversightCoordinatorTests {
    private let conversation = UUID()

    private func coordinator(
        _ publisher: RecordingIntentPublisher,
        questionTimeout: Duration = .seconds(30),
        handoffTimeout: Duration = .seconds(30)
    ) -> ComputerUseOversightCoordinator {
        ComputerUseOversightCoordinator(
            publish: { await publisher.publish($0, $1) },
            questionTimeout: questionTimeout,
            handoffTimeout: handoffTimeout
        )
    }

    private func oversight(_ coordinator: ComputerUseOversightCoordinator) -> ComputerUseConversationOversight {
        ComputerUseConversationOversight(coordinator: coordinator, conversationID: conversation, lifecycleID: "call-1", targetLabel: "This Mac")
    }

    /// Waits until the coordinator has a pending request, then returns it.
    private func pending(_ coordinator: ComputerUseOversightCoordinator) async throws -> ComputerUsePendingRequest {
        for _ in 0..<500 {
            if let request = await coordinator.pending(conversationID: conversation).first { return request }
            await Task.yield()
        }
        throw CancellationError()
    }

    @Test("A question blocks until answered, published to the parent conversation and then cleared")
    func questionAnswered() async throws {
        let publisher = RecordingIntentPublisher()
        let coordinator = coordinator(publisher)
        async let reply = oversight(coordinator).askUser("Which file should I export?")
        let request = try await pending(coordinator)
        #expect(request.kind == .question)
        #expect(request.prompt == "Which file should I export?")
        #expect(await coordinator.resolve(id: request.id, conversationID: conversation, resolution: .answered("The second one")))
        #expect(await reply == .answered("The second one"))
        #expect(await publisher.kinds == [.computerUseRequest, .computerUseRequestCleared])
        #expect(await publisher.published.allSatisfy { $0.0 == conversation })
        #expect(await coordinator.pending(conversationID: conversation).isEmpty)
    }

    @Test("A resolution for another conversation, an unknown id, or the wrong kind is rejected")
    func rejectsMismatches() async throws {
        let publisher = RecordingIntentPublisher()
        let coordinator = coordinator(publisher)
        async let reply = oversight(coordinator).askUser("Which file?")
        let request = try await pending(coordinator)
        #expect(await !coordinator.resolve(id: request.id, conversationID: UUID(), resolution: .answered("x")))
        #expect(await !coordinator.resolve(id: "nope", conversationID: conversation, resolution: .answered("x")))
        #expect(await !coordinator.resolve(id: request.id, conversationID: conversation, resolution: .handedBack(note: nil)))
        #expect(await coordinator.resolve(id: request.id, conversationID: conversation, resolution: .answered("ok")))
        #expect(await reply == .answered("ok"))
    }

    @Test("An unanswered question times out as unavailable")
    func questionTimesOut() async {
        let publisher = RecordingIntentPublisher()
        let reply = await oversight(coordinator(publisher, questionTimeout: .milliseconds(20))).askUser("Anyone there?")
        #expect(reply == .unavailable)
        #expect(await publisher.kinds == [.computerUseRequest, .computerUseRequestCleared])
    }

    @Test("A handoff waits for the user to hand back, or reports a decline")
    func handoff() async throws {
        let publisher = RecordingIntentPublisher()
        let coordinator = coordinator(publisher)
        let request = ComputerUseHandoffRequest(reason: .login, prompt: "Sign in to the portal", target: "macos-host")
        async let handedBack = oversight(coordinator).handoff(request)
        let first = try await pending(coordinator)
        #expect(first.kind == .handoff)
        #expect(first.reason == "login")
        #expect(await coordinator.resolve(id: first.id, conversationID: conversation, resolution: .handedBack(note: "signed in")))
        #expect(await handedBack == .handedBack(note: "signed in"))

        async let declined = oversight(coordinator).handoff(request)
        let second = try await pending(coordinator)
        #expect(await coordinator.resolve(id: second.id, conversationID: conversation, resolution: .declined))
        #expect(await declined == .declined)
    }

    @Test("An answer that arrives while the request is still being published is not lost")
    func earlyAnswer() async {
        let box = CoordinatorBox()
        let coordinator = ComputerUseOversightCoordinator(publish: { conversationID, intent in
            // Answer from inside the publish, before the waiter has registered.
            guard intent.kind == .computerUseRequest, let id = intent.computerUse?.requestID, let coordinator = await box.value else { return }
            _ = await coordinator.resolve(id: id, conversationID: conversationID, resolution: .answered("fast"))
        })
        await box.set(coordinator)
        #expect(await oversight(coordinator).askUser("Quick?") == .answered("fast"))
    }

    @Test("Cancelling the waiting run clears the request")
    func cancellation() async throws {
        let publisher = RecordingIntentPublisher()
        let coordinator = coordinator(publisher)
        let waiter = Task { await oversight(coordinator).askUser("Which file?") }
        _ = try await pending(coordinator)
        waiter.cancel()
        #expect(await waiter.value == .unavailable)
        #expect(await coordinator.pending(conversationID: conversation).isEmpty)
        #expect(await publisher.kinds.last == .computerUseRequestCleared)
    }
}
