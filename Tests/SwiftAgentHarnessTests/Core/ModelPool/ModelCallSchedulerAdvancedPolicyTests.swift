import Foundation
import Testing
@testable import SwiftAgentHarness

private actor AcquireOrderRecorder {
    var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
}

@Suite("ModelCallScheduler advanced policy", .serialized)
struct ModelCallSchedulerAdvancedPolicyTests {
    private func waitForQueueDepth(
        scheduler: ModelCallScheduler,
        atLeast expected: Int,
        timeoutMS: Int = 2_000
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        while Date() < deadline {
            let snap = await scheduler.poolHealthSnapshot()
            if snap.queueDepth >= expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Per-model cap blocks second call on same model")
    func perModelCapBlocksSameModel() async throws {
        let modelID = UUID()
        let scheduler = ModelCallScheduler(
            maxConcurrent: 4,
            policy: ModelCallSchedulerPolicy(maxConcurrentPerModel: 1)
        )

        await scheduler.acquire(for: modelID, priority: .foreground)
        let second = Task {
            await scheduler.acquire(for: modelID, priority: .foreground)
            await scheduler.release(for: modelID)
        }
        await waitForQueueDepth(scheduler: scheduler, atLeast: 1)
        await scheduler.release(for: modelID)
        await second.value
    }

    @Test("Per-credential cap blocks calls sharing credential")
    func perCredentialCapBlocksSharedCredential() async throws {
        let scheduler = ModelCallScheduler(
            maxConcurrent: 4,
            policy: ModelCallSchedulerPolicy(maxConcurrentPerCredential: 1)
        )
        let firstReservation = ModelCallReservation(
            modelID: UUID(),
            priority: .foreground,
            credentialKey: "providerA#default"
        )
        let first = await scheduler.acquire(reservation: firstReservation)

        let second = Task {
            let secondReservation = ModelCallReservation(
                modelID: UUID(),
                priority: .foreground,
                credentialKey: "providerA#default"
            )
            let acquired = await scheduler.acquire(reservation: secondReservation)
            await scheduler.release(acquisition: acquired)
        }

        await waitForQueueDepth(scheduler: scheduler, atLeast: 1)
        await scheduler.release(acquisition: first)
        await second.value
    }

    @Test("Token bucket admission unblocks after refill window")
    func tokenBucketRefillUnblocks() async throws {
        let scheduler = ModelCallScheduler(
            maxConcurrent: 2,
            policy: ModelCallSchedulerPolicy(
                tokenBucketPerMinute: 6000, // 100 tokens/sec
                bucketScope: .global,
                bucketRefillGranularitySeconds: 0.05
            )
        )

        let first = await scheduler.acquire(
            reservation: ModelCallReservation(
                modelID: UUID(),
                priority: .foreground,
                estimatedTotalTokens: 6000
            )
        )

        let secondStarted = Date()
        let second = Task {
            let acquired = await scheduler.acquire(
                reservation: ModelCallReservation(
                    modelID: UUID(),
                    priority: .foreground,
                    estimatedTotalTokens: 100
                )
            )
            await scheduler.release(acquisition: acquired)
            return Date().timeIntervalSince(secondStarted)
        }

        await waitForQueueDepth(scheduler: scheduler, atLeast: 1)
        let waitSeconds = await second.value
        #expect(waitSeconds >= 0.7)
        await scheduler.release(acquisition: first)
    }

    @Test("Round-robin fairness serves different conversation before same-conversation backlog")
    func roundRobinFairnessAcrossConversations() async throws {
        let scheduler = ModelCallScheduler(
            maxConcurrent: 1,
            backgroundStarvationGrace: 60,
            policy: ModelCallSchedulerPolicy(fairness: .roundRobinByConversation)
        )
        let modelID = UUID()
        let conversationA = UUID()
        let conversationB = UUID()
        let order = AcquireOrderRecorder()

        let held = await scheduler.acquire(
            reservation: ModelCallReservation(
                modelID: modelID,
                priority: .foreground,
                conversationID: UUID()
            )
        )

        let a1 = Task {
            let acq = await scheduler.acquire(
                reservation: ModelCallReservation(
                    modelID: modelID,
                    priority: .foreground,
                    conversationID: conversationA
                )
            )
            await order.append("A1")
            await scheduler.release(acquisition: acq)
        }
        await waitForQueueDepth(scheduler: scheduler, atLeast: 1)

        let a2 = Task {
            let acq = await scheduler.acquire(
                reservation: ModelCallReservation(
                    modelID: modelID,
                    priority: .foreground,
                    conversationID: conversationA
                )
            )
            await order.append("A2")
            await scheduler.release(acquisition: acq)
        }
        await waitForQueueDepth(scheduler: scheduler, atLeast: 2)

        let b1 = Task {
            let acq = await scheduler.acquire(
                reservation: ModelCallReservation(
                    modelID: modelID,
                    priority: .foreground,
                    conversationID: conversationB
                )
            )
            await order.append("B1")
            await scheduler.release(acquisition: acq)
        }
        await waitForQueueDepth(scheduler: scheduler, atLeast: 3)

        await scheduler.release(acquisition: held)
        await a1.value
        await a2.value
        await b1.value

        let recorded = await order.entries
        #expect(recorded == ["A1", "B1", "A2"])
    }
}
