import Foundation

actor RuntimeLaneSubAgentRunScheduler: SubAgentRunScheduling {
    private let runtimeLaneCoordinator: RuntimeLaneCoordinator
    private var runIDByLifecycleID: [String: UUID] = [:]
    private var inFlightByParentConversationID: [UUID: Set<UUID>] = [:]

    init(runtimeLaneCoordinator: RuntimeLaneCoordinator) {
        self.runtimeLaneCoordinator = runtimeLaneCoordinator
    }

    func acquire(reservation: SubAgentRunReservation) async throws -> SubAgentRunAcquisition {
        let runID = UUID()
        if let admission = await runtimeLaneCoordinator.tryAcquireSubagentRun(
            parentRunID: reservation.parentRunID,
            parentConversationID: reservation.parentConversationID,
            runID: runID
        ) {
            throw admission
        }
        runIDByLifecycleID[reservation.lifecycleID] = runID
        var inFlight = inFlightByParentConversationID[reservation.parentConversationID] ?? Set()
        inFlight.insert(runID)
        inFlightByParentConversationID[reservation.parentConversationID] = inFlight
        return SubAgentRunAcquisition(reservation: reservation, runID: runID)
    }

    func release(acquisition: SubAgentRunAcquisition) async {
        await runtimeLaneCoordinator.releaseSubagentRun(runID: acquisition.runID)
        runIDByLifecycleID.removeValue(forKey: acquisition.reservation.lifecycleID)
        var inFlight = inFlightByParentConversationID[acquisition.reservation.parentConversationID] ?? Set()
        inFlight.remove(acquisition.runID)
        if inFlight.isEmpty {
            inFlightByParentConversationID.removeValue(forKey: acquisition.reservation.parentConversationID)
        } else {
            inFlightByParentConversationID[acquisition.reservation.parentConversationID] = inFlight
        }
    }

    func inFlightCount(parentConversationID: UUID) async -> Int {
        inFlightByParentConversationID[parentConversationID]?.count ?? 0
    }
}

actor SubAgentInvocationCoordinator: SubAgentInvocationLifecycleTracking {
    private let scheduler: any SubAgentRunScheduling
    private var acquisitionsByLifecycleID: [String: SubAgentRunAcquisition] = [:]

    init(scheduler: any SubAgentRunScheduling) {
        self.scheduler = scheduler
    }

    func beginInvocation(
        reservation: SubAgentRunReservation
    ) async throws -> SubAgentRunAcquisition {
        let acquisition = try await scheduler.acquire(reservation: reservation)
        acquisitionsByLifecycleID[reservation.lifecycleID] = acquisition
        return acquisition
    }

    func endInvocation(_ acquisition: SubAgentRunAcquisition) async {
        await endInvocation(lifecycleID: acquisition.reservation.lifecycleID)
    }

    func endInvocation(lifecycleID: String) async {
        guard let acquisition = acquisitionsByLifecycleID.removeValue(forKey: lifecycleID) else { return }
        await scheduler.release(acquisition: acquisition)
    }

    func inFlightCount(parentConversationID: UUID) async -> Int {
        await scheduler.inFlightCount(parentConversationID: parentConversationID)
    }

    func recordTransition(
        parentConversationID: UUID,
        lifecycleID: String,
        phase: SubAgentInvocationPhase
    ) async {
        _ = (parentConversationID, lifecycleID, phase)
    }
}
