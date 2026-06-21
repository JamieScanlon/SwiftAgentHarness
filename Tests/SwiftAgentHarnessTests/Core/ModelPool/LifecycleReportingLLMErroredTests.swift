import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor PhaseRecorder {
    private(set) var phases: [ModelInvocationPhase] = []
    func append(_ phase: ModelInvocationPhase) {
        phases.append(phase)
    }
}

/// Stub that throws a configured error on send / generateImage so we can drive the new
/// `.errored` / `.cancelled` lifecycle paths.
private struct AlwaysFailingLLM: LLMProtocol {
    let error: Error

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { $0.finish() }
    }
    nonisolated func getModelName() -> String { "fail" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        throw error
    }
    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw error
    }
}

@Suite("LifecycleReportingLLM .errored / .cancelled on terminal failure")
struct LifecycleReportingLLMErroredTests {

    @Test("send: terminal failure records .connecting then .errored")
    func sendErroredRecorded() async throws {
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let modelID = UUID()
        let lifecycle = LifecycleReportingLLM(
            baseLLM: AlwaysFailingLLM(error: LLMError.invalidRequest("nope")),
            modelID: modelID,
            coordinator: coordinator
        )

        await #expect(throws: LLMError.self) {
            _ = try await lifecycle.send([], config: LLMRequestConfig())
        }

        let phases = await recorder.phases
        #expect(phases.contains(.connecting))
        #expect(phases.contains(.errored))
        #expect(!phases.contains(.done))
    }

    @Test("send: cancellation records .cancelled, not .errored")
    func sendCancelledRecorded() async throws {
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let modelID = UUID()
        let lifecycle = LifecycleReportingLLM(
            baseLLM: AlwaysFailingLLM(error: CancellationError()),
            modelID: modelID,
            coordinator: coordinator
        )

        await #expect(throws: CancellationError.self) {
            _ = try await lifecycle.send([], config: LLMRequestConfig())
        }

        let phases = await recorder.phases
        #expect(phases.contains(.cancelled))
        #expect(!phases.contains(.errored))
    }

    @Test("generateImage: terminal failure records .errored")
    func generateImageErroredRecorded() async throws {
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let modelID = UUID()
        let lifecycle = LifecycleReportingLLM(
            baseLLM: AlwaysFailingLLM(error: LLMError.unsupportedCapability(.imageGeneration)),
            modelID: modelID,
            coordinator: coordinator
        )

        await #expect(throws: LLMError.self) {
            _ = try await lifecycle.generateImage(ImageGenerationRequestConfig(prompt: "test"))
        }

        let phases = await recorder.phases
        #expect(phases.contains(.errored))
        #expect(!phases.contains(.done))
    }

    @Test("generateImage: cancellation records .cancelled")
    func generateImageCancelledRecorded() async throws {
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let modelID = UUID()
        let lifecycle = LifecycleReportingLLM(
            baseLLM: AlwaysFailingLLM(error: CancellationError()),
            modelID: modelID,
            coordinator: coordinator
        )

        await #expect(throws: CancellationError.self) {
            _ = try await lifecycle.generateImage(ImageGenerationRequestConfig(prompt: "test"))
        }

        let phases = await recorder.phases
        #expect(phases.contains(.cancelled))
        #expect(!phases.contains(.errored))
    }

    // MARK: - Budget rejection integration

    private struct AlwaysSucceedingLLM: LLMProtocol {
        nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
        nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
        nonisolated func getModelName() -> String { "ok" }
        nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
        func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
            LLMResponse(content: "should-not-reach", toolCalls: [])
        }
        nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
            ImageGenerationResponse(images: [])
        }
    }

    private struct RejectingBudget: BudgetAccounting {
        func authorize(
            policy: BudgetPolicy,
            modelID: UUID,
            conversationID: UUID?,
            accountID: UUID?,
            projectedCostUSD: Double?
        ) async throws {
            let _ = (policy, modelID, conversationID, accountID, projectedCostUSD)
            throw LLMError.quotaExceeded
        }
        func recordCompletion(
            policy: BudgetPolicy,
            modelID: UUID,
            conversationID: UUID?,
            accountID: UUID?,
            actualCostUSD: Double?
        ) async {
            let _ = (policy, modelID, conversationID, accountID, actualCostUSD)
            Issue.record("recordCompletion must not fire when authorize rejects")
        }
    }

    @Test("Budget rejection through LifecycleReportingLLM(BudgetEnforcingLLM(...)) records .errored exactly once on send")
    func budgetRejectRecordsErroredOnceSend() async throws {
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let modelID = UUID()
        let inner = AlwaysSucceedingLLM()
        let budgetGated = BudgetEnforcingLLM(
            base: inner,
            accounting: RejectingBudget(),
            policy: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: nil),
            modelID: modelID,
            conversationID: UUID(),
            modelCost: nil
        )
        let lifecycle = LifecycleReportingLLM(
            baseLLM: budgetGated,
            modelID: modelID,
            coordinator: coordinator
        )

        await #expect(throws: LLMError.self) {
            _ = try await lifecycle.send([], config: LLMRequestConfig())
        }

        let phases = await recorder.phases
        let erroredCount = phases.filter { $0 == .errored }.count
        #expect(erroredCount == 1, "Expected exactly one .errored phase, got phases=\(phases)")
        #expect(!phases.contains(.done))
    }

    @Test("Budget rejection through LifecycleReportingLLM(BudgetEnforcingLLM(...)) records .errored exactly once on generateImage")
    func budgetRejectRecordsErroredOnceGenerateImage() async throws {
        let recorder = PhaseRecorder()
        let coordinator = ModelInvocationCoordinator { _, payload in
            await recorder.append(payload.phase)
        }
        let modelID = UUID()
        let inner = AlwaysSucceedingLLM()
        let budgetGated = BudgetEnforcingLLM(
            base: inner,
            accounting: RejectingBudget(),
            policy: .enabled(maxUSDPerCall: 0.01, maxUSDPerConversation: nil),
            modelID: modelID,
            conversationID: UUID(),
            modelCost: nil
        )
        let lifecycle = LifecycleReportingLLM(
            baseLLM: budgetGated,
            modelID: modelID,
            coordinator: coordinator
        )

        await #expect(throws: LLMError.self) {
            _ = try await lifecycle.generateImage(ImageGenerationRequestConfig(prompt: "x"))
        }

        let phases = await recorder.phases
        let erroredCount = phases.filter { $0 == .errored }.count
        #expect(erroredCount == 1, "Expected exactly one .errored phase, got phases=\(phases)")
        #expect(!phases.contains(.done))
    }
}
