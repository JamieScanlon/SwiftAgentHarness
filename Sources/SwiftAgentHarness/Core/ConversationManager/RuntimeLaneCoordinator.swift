import Foundation

public struct RuntimeLaneConfiguration: Sendable, Equatable {
    public var sessionMaxConcurrentRuns: Int
    public var globalMainLaneLimit: Int
    public var globalSubagentLaneLimit: Int
    public var globalCronLaneLimit: Int
    public var maxChildrenPerAgent: Int

    public static let `default` = RuntimeLaneConfiguration(
        sessionMaxConcurrentRuns: 1,
        globalMainLaneLimit: 4,
        globalSubagentLaneLimit: 8,
        globalCronLaneLimit: 2,
        maxChildrenPerAgent: 5
    )

    public init(
        sessionMaxConcurrentRuns: Int = 1,
        globalMainLaneLimit: Int = 4,
        globalSubagentLaneLimit: Int = 8,
        globalCronLaneLimit: Int = 2,
        maxChildrenPerAgent: Int = 5
    ) {
        self.sessionMaxConcurrentRuns = max(1, sessionMaxConcurrentRuns)
        self.globalMainLaneLimit = max(1, globalMainLaneLimit)
        self.globalSubagentLaneLimit = max(1, globalSubagentLaneLimit)
        self.globalCronLaneLimit = max(1, globalCronLaneLimit)
        self.maxChildrenPerAgent = min(20, max(1, maxChildrenPerAgent))
    }
}

enum RuntimeLaneAdmissionError: Error, Sendable, Equatable {
    case sessionLaneBusy(activeRunID: UUID?)
    case globalMainLaneAtCapacity(limit: Int)
    case globalSubagentLaneAtCapacity(limit: Int)
    case globalCronLaneAtCapacity(limit: Int)
    case parentFanoutExceeded(limit: Int)
}

actor RuntimeLaneCoordinator {
    private let configuration: RuntimeLaneConfiguration
    private var activeRunsBySessionKey: [String: UUID] = [:]
    private var activeRunIDsByGlobalLane: [RuntimeGlobalLaneKind: Set<UUID>] = [
        .main: [],
        .subagent: [],
        .cron: [],
    ]
    private var admissionContextByRunID: [UUID: RunLaneAdmissionContext] = [:]
    private var childRunParentIdentityByRunID: [UUID: String] = [:]
    private var childRunCountByParentIdentity: [String: Int] = [:]

    init(configuration: RuntimeLaneConfiguration = .default) {
        self.configuration = configuration
    }

    func tryAcquire(_ context: RunLaneAdmissionContext) -> RuntimeLaneAdmissionError? {
        if context.globalLane != .subagent,
           let active = activeRunsBySessionKey[context.sessionKey], active != context.runID {
            return .sessionLaneBusy(activeRunID: active)
        }
        if let globalError = tryAcquireGlobalLane(context) {
            return globalError
        }
        if context.globalLane != .subagent {
            activeRunsBySessionKey[context.sessionKey] = context.runID
        }
        activeRunIDsByGlobalLane[context.globalLane, default: []].insert(context.runID)
        admissionContextByRunID[context.runID] = context
        return nil
    }

    func release(runID: UUID) {
        guard let context = admissionContextByRunID.removeValue(forKey: runID) else { return }
        release(context)
    }

    func release(_ context: RunLaneAdmissionContext) {
        if context.globalLane != .subagent,
           activeRunsBySessionKey[context.sessionKey] == context.runID {
            activeRunsBySessionKey.removeValue(forKey: context.sessionKey)
        }
        activeRunIDsByGlobalLane[context.globalLane]?.remove(context.runID)
        admissionContextByRunID.removeValue(forKey: context.runID)
        if context.globalLane == .subagent {
            releaseSubagentFanoutTracking(runID: context.runID)
        } else {
            childRunCountByParentIdentity.removeValue(forKey: context.runID.uuidString.lowercased())
        }
    }

    func tryAcquireMainRun(sessionKey: String, runID: UUID) -> RuntimeLaneAdmissionError? {
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: sessionKey,
                runID: runID,
                origin: .interactive
            )
        )
        return tryAcquire(context)
    }

    func releaseMainRun(sessionKey: String, runID: UUID) {
        if let stored = admissionContextByRunID[runID] {
            release(stored)
            return
        }
        release(
            RunLaneAdmissionContext(
                sessionKey: sessionKey,
                runID: runID,
                globalLane: .main
            )
        )
    }

    func tryAcquireSubagentRun(
        parentRunID: UUID?,
        parentConversationID: UUID? = nil,
        runID: UUID,
        sessionKey: String = "subagent:anonymous"
    ) -> RuntimeLaneAdmissionError? {
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: sessionKey,
                runID: runID,
                origin: .subagentSpawn,
                parentRunID: parentRunID,
                parentConversationID: parentConversationID
            )
        )
        return tryAcquire(context)
    }

    func releaseSubagentRun(runID: UUID) {
        release(runID: runID)
    }

    private func tryAcquireGlobalLane(_ context: RunLaneAdmissionContext) -> RuntimeLaneAdmissionError? {
        switch context.globalLane {
        case .main:
            let count = activeRunIDsByGlobalLane[.main, default: []].count
            if count >= configuration.globalMainLaneLimit {
                return .globalMainLaneAtCapacity(limit: configuration.globalMainLaneLimit)
            }
        case .subagent:
            let count = activeRunIDsByGlobalLane[.subagent, default: []].count
            if count >= configuration.globalSubagentLaneLimit {
                return .globalSubagentLaneAtCapacity(limit: configuration.globalSubagentLaneLimit)
            }
            if let fanoutError = tryAcquireSubagentFanout(context) {
                return fanoutError
            }
        case .cron:
            let count = activeRunIDsByGlobalLane[.cron, default: []].count
            if count >= configuration.globalCronLaneLimit {
                return .globalCronLaneAtCapacity(limit: configuration.globalCronLaneLimit)
            }
        }
        return nil
    }

    private func tryAcquireSubagentFanout(_ context: RunLaneAdmissionContext) -> RuntimeLaneAdmissionError? {
        let parentIdentity: String? = if let parentConversationID = context.parentConversationID {
            parentConversationID.uuidString.lowercased()
        } else if let parentRunID = context.parentRunID {
            parentRunID.uuidString.lowercased()
        } else {
            nil
        }
        guard let parentIdentity else { return nil }
        let childCount = childRunCountByParentIdentity[parentIdentity, default: 0]
        if childCount >= configuration.maxChildrenPerAgent {
            return .parentFanoutExceeded(limit: configuration.maxChildrenPerAgent)
        }
        childRunParentIdentityByRunID[context.runID] = parentIdentity
        childRunCountByParentIdentity[parentIdentity] = childCount + 1
        return nil
    }

    private func releaseSubagentFanoutTracking(runID: UUID) {
        if let parentIdentity = childRunParentIdentityByRunID.removeValue(forKey: runID) {
            let count = childRunCountByParentIdentity[parentIdentity, default: 0]
            if count <= 1 {
                childRunCountByParentIdentity.removeValue(forKey: parentIdentity)
            } else {
                childRunCountByParentIdentity[parentIdentity] = count - 1
            }
        }
    }
}
