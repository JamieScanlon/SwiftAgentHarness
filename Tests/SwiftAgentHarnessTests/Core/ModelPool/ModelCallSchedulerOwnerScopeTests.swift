import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Model call scheduler owner scope")
struct ModelCallSchedulerOwnerScopeTests {
    @Test("per-owner concurrent cap isolates owners under strict tenancy")
    func perOwnerConcurrentCapIsolatesOwners() async {
        let strict = TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
        let ownerA = UUID()
        let ownerB = UUID()
        let modelID = UUID()
        let scheduler = ModelCallScheduler(
            maxConcurrent: 4,
            policy: ModelCallSchedulerPolicy(maxConcurrentPerOwner: 1),
            tenancyPolicy: strict
        )

        let reservationA = ModelCallReservation(
            modelID: modelID,
            priority: .foreground,
            ownerAccountID: ownerA
        )
        let reservationB = ModelCallReservation(
            modelID: modelID,
            priority: .foreground,
            ownerAccountID: ownerB
        )

        let acquisitionA1 = await scheduler.acquire(reservation: reservationA)

        let blockedSecondA = Task {
            await scheduler.acquire(reservation: reservationA)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let acquisitionB = await scheduler.acquire(reservation: reservationB)
        #expect(blockedSecondA.isCancelled == false)

        await scheduler.release(acquisition: acquisitionA1)
        let acquisitionA2 = await blockedSecondA.value

        await scheduler.release(acquisition: acquisitionB)
        await scheduler.release(acquisition: acquisitionA2)
    }
}
