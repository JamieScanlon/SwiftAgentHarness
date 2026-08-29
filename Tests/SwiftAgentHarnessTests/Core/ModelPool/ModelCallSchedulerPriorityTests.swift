import Foundation
import Testing
@testable import SwiftAgentHarness

private actor PriorityCollector {
    var poolHealth: [(queueDepth: Int, inFlight: Int)] = []

    func appendHealth(_ payload: PoolHealthPayload) {
        poolHealth.append((payload.queueDepth, payload.inFlight))
    }
}

@Suite("ModelCallScheduler priority", .serialized)
struct ModelCallSchedulerPriorityTests {
    private func waitForQueueState(
        scheduler: ModelCallScheduler,
        foreground: Int,
        background: Int,
        timeoutMS: Int = 10_000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000.0)
        while Date() < deadline {
            let snapshot = await scheduler.poolHealthSnapshot()
            let byPriority = snapshot.queueDepthByPriority
            let hasForeground = (byPriority?.foreground ?? snapshot.queueDepth) >= foreground
            let hasBackground = (byPriority?.background ?? 0) >= background
            if hasForeground && hasBackground {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: - Pure helper

    @Test("selectNextWaiter returns nil when both queues empty")
    func selectEmpty() {
        let choice = ModelCallScheduler.selectNextWaiter(
            foregroundCount: 0,
            oldestBackgroundEnqueuedAt: nil,
            now: Date(),
            starvationGrace: 5
        )
        #expect(choice == nil)
    }

    @Test("selectNextWaiter returns foreground when only foreground queued")
    func selectOnlyForeground() {
        let choice = ModelCallScheduler.selectNextWaiter(
            foregroundCount: 2,
            oldestBackgroundEnqueuedAt: nil,
            now: Date(),
            starvationGrace: 5
        )
        #expect(choice == .foreground)
    }

    @Test("selectNextWaiter returns background when only background queued")
    func selectOnlyBackground() {
        let now = Date()
        let choice = ModelCallScheduler.selectNextWaiter(
            foregroundCount: 0,
            oldestBackgroundEnqueuedAt: now.addingTimeInterval(-1),
            now: now,
            starvationGrace: 5
        )
        #expect(choice == .background)
    }

    @Test("selectNextWaiter prefers foreground when background is under starvation grace")
    func selectForegroundOverYoungBackground() {
        let now = Date()
        let choice = ModelCallScheduler.selectNextWaiter(
            foregroundCount: 1,
            oldestBackgroundEnqueuedAt: now.addingTimeInterval(-1),
            now: now,
            starvationGrace: 5
        )
        #expect(choice == .foreground)
    }

    @Test("selectNextWaiter promotes background when waited >= starvation grace")
    func selectBackgroundAfterStarvationGrace() {
        let now = Date()
        let choice = ModelCallScheduler.selectNextWaiter(
            foregroundCount: 1,
            oldestBackgroundEnqueuedAt: now.addingTimeInterval(-6),
            now: now,
            starvationGrace: 5
        )
        #expect(choice == .background)
    }

    @Test("selectNextWaiter promotes background exactly at grace boundary")
    func selectBackgroundAtGraceBoundary() {
        let now = Date()
        let choice = ModelCallScheduler.selectNextWaiter(
            foregroundCount: 1,
            oldestBackgroundEnqueuedAt: now.addingTimeInterval(-5),
            now: now,
            starvationGrace: 5
        )
        #expect(choice == .background)
    }

    // MARK: - Actor-level scheduling

    @Test("Foreground waiter resumes before background under capacity pressure")
    func foregroundBeatsBackground() async throws {
        let scheduler = ModelCallScheduler(maxConcurrent: 1, backgroundStarvationGrace: 60)
        let modelID = UUID()
        // Take the only slot.
        await scheduler.acquire(for: modelID, priority: .foreground)

        let order = OrderRecorder()

        let bgTask = Task {
            await scheduler.acquire(for: modelID, priority: .background)
            await order.record("bg")
            await scheduler.release(for: modelID)
        }
        // Ensure background enqueues first.
        #expect(await waitForQueueState(scheduler: scheduler, foreground: 0, background: 1))

        let fgTask = Task {
            await scheduler.acquire(for: modelID, priority: .foreground)
            await order.record("fg")
            await scheduler.release(for: modelID)
        }
        #expect(await waitForQueueState(scheduler: scheduler, foreground: 1, background: 1))

        // Release the in-flight slot; foreground should resume first because background is well under grace.
        await scheduler.release(for: modelID)

        await fgTask.value
        await bgTask.value

        let recorded = await order.entries
        #expect(recorded == ["fg", "bg"])
    }

    @Test("FIFO is preserved within a single priority class")
    func fifoWithinClass() async throws {
        let scheduler = ModelCallScheduler(maxConcurrent: 1, backgroundStarvationGrace: 60)
        let modelID = UUID()
        await scheduler.acquire(for: modelID, priority: .foreground)

        let order = OrderRecorder()

        let first = Task {
            await scheduler.acquire(for: modelID, priority: .foreground)
            await order.record("fg1")
            await scheduler.release(for: modelID)
        }
        #expect(await waitForQueueState(scheduler: scheduler, foreground: 1, background: 0))
        let second = Task {
            await scheduler.acquire(for: modelID, priority: .foreground)
            await order.record("fg2")
            await scheduler.release(for: modelID)
        }
        #expect(await waitForQueueState(scheduler: scheduler, foreground: 2, background: 0))

        await scheduler.release(for: modelID)
        await first.value
        await second.value

        let recorded = await order.entries
        #expect(recorded == ["fg1", "fg2"])
    }

    @Test("Starvation grace promotes background ahead of newer foreground")
    func starvationGracePromotesBackground() async throws {
        // Small grace so the test stays fast.
        let scheduler = ModelCallScheduler(maxConcurrent: 1, backgroundStarvationGrace: 0.1)
        let modelID = UUID()
        await scheduler.acquire(for: modelID, priority: .foreground)

        let order = OrderRecorder()

        let bgTask = Task {
            await scheduler.acquire(for: modelID, priority: .background)
            await order.record("bg")
            await scheduler.release(for: modelID)
        }
        #expect(await waitForQueueState(scheduler: scheduler, foreground: 0, background: 1))
        // Let background sit in the queue past the grace window.
        try await Task.sleep(for: .milliseconds(250))

        let fgTask = Task {
            await scheduler.acquire(for: modelID, priority: .foreground)
            await order.record("fg")
            await scheduler.release(for: modelID)
        }
        #expect(await waitForQueueState(scheduler: scheduler, foreground: 1, background: 1))

        await scheduler.release(for: modelID)
        await bgTask.value
        await fgTask.value

        let recorded = await order.entries
        #expect(recorded == ["bg", "fg"])
    }

    @Test("pool/health.queueDepth combines foreground and background waiters")
    func combinedQueueDepth() async throws {
        let scheduler = ModelCallScheduler(maxConcurrent: 1, backgroundStarvationGrace: 60)
        let modelID = UUID()
        // Hold the only slot.
        await scheduler.acquire(for: modelID, priority: .foreground)

        let bg = Task { await scheduler.acquire(for: modelID, priority: .background) }
        let fg = Task { await scheduler.acquire(for: modelID, priority: .foreground) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let snap = await scheduler.poolHealthSnapshot()
        #expect(snap.queueDepth == 2)
        #expect(snap.inFlight == 1)
        #expect(snap.maxConcurrent == 1)

        // Drain to avoid leaking tasks.
        await scheduler.release(for: modelID)
        await fg.value
        await scheduler.release(for: modelID)
        await bg.value
        await scheduler.release(for: modelID)
    }
}

private actor OrderRecorder {
    var entries: [String] = []
    func record(_ value: String) {
        entries.append(value)
    }
}
