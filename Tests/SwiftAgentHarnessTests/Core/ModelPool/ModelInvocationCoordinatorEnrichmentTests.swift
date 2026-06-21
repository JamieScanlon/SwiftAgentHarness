import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ModelInvocationCoordinator — communication-layer enrichment")
struct ModelInvocationCoordinatorEnrichmentTests {
    // MARK: - lastCompletedAt

    @Test("lastCompletedAt is set on .done")
    func lastCompletedSetOnDone() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        let beforeDone = await coordinator.snapshot(for: modelID)
        #expect(beforeDone.lastCompletedAt == nil)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: callID)
        let afterDone = await coordinator.snapshot(for: modelID)
        #expect(afterDone.lastCompletedAt != nil)
    }

    @Test("lastCompletedAt is set on .errored")
    func lastCompletedSetOnErrored() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .errored, callID: callID)
        let snapshot = await coordinator.snapshot(for: modelID)
        #expect(snapshot.lastCompletedAt != nil)
    }

    @Test("lastCompletedAt is set on .cancelled")
    func lastCompletedSetOnCancelled() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .cancelled, callID: callID)
        let snapshot = await coordinator.snapshot(for: modelID)
        #expect(snapshot.lastCompletedAt != nil)
    }

    @Test("lastCompletedAt stays nil for non-terminal phases")
    func lastCompletedNilForNonTerminal() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .connecting, callID: callID)
        await coordinator.recordTransition(modelID: modelID, phase: .streaming, callID: callID)
        await coordinator.recordTransition(modelID: modelID, phase: .toolCalling, callID: callID)
        let snapshot = await coordinator.snapshot(for: modelID)
        #expect(snapshot.lastCompletedAt == nil)
    }

    @Test("lastCompletedAt updates on subsequent terminal transitions")
    func lastCompletedUpdatesOnRepeat() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let firstCall = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: firstCall)
        let firstSnapshot = await coordinator.snapshot(for: modelID)
        let firstTerminal = firstSnapshot.lastCompletedAt
        try await Task.sleep(nanoseconds: 5_000_000)
        let secondCall = await coordinator.beginCall(modelID: modelID)
        await coordinator.recordTransition(modelID: modelID, phase: .done, callID: secondCall)
        let secondSnapshot = await coordinator.snapshot(for: modelID)
        let secondTerminal = secondSnapshot.lastCompletedAt
        #expect(firstTerminal != nil)
        #expect(secondTerminal != nil)
        #expect((secondTerminal ?? .distantPast) >= (firstTerminal ?? .distantFuture))
    }

    // MARK: - activeCall(forConversationID:)

    @Test("activeCall returns nil before any beginCall")
    func activeCallNilBeforeBegin() async throws {
        let coordinator = ModelInvocationCoordinator()
        let conversationID = UUID()
        let result = await coordinator.activeCall(forConversationID: conversationID)
        #expect(result == nil)
    }

    @Test("activeCall returns (modelID, callID) during in-flight call")
    func activeCallDuringInFlight() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let conversationID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID, conversationID: conversationID)
        let result = await coordinator.activeCall(forConversationID: conversationID)
        #expect(result?.modelID == modelID)
        #expect(result?.callID == callID)
    }

    @Test("activeCall returns nil after endCall")
    func activeCallNilAfterEnd() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let conversationID = UUID()
        let callID = await coordinator.beginCall(modelID: modelID, conversationID: conversationID)
        await coordinator.endCall(modelID: modelID, callID: callID)
        let result = await coordinator.activeCall(forConversationID: conversationID)
        #expect(result == nil)
    }

    @Test("activeCall returns nil for unrelated conversation IDs")
    func activeCallNilForUnrelated() async throws {
        let coordinator = ModelInvocationCoordinator()
        let modelID = UUID()
        let activeConvo = UUID()
        let unrelated = UUID()
        _ = await coordinator.beginCall(modelID: modelID, conversationID: activeConvo)
        let result = await coordinator.activeCall(forConversationID: unrelated)
        #expect(result == nil)
    }
}
