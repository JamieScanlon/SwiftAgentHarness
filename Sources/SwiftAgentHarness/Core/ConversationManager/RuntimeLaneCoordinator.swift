import Foundation

public struct RuntimeLaneConfiguration: Sendable, Equatable {
    public var sessionMaxConcurrentRuns: Int
    public var globalMainLaneLimit: Int
    public var globalSubagentLaneLimit: Int
    public var globalCronLaneLimit: Int
    public var maxChildrenPerAgent: Int
    public var perOwnerSubagentLaneLimit: Int?
    public var perOwnerSubagentFanoutLimit: Int?

    public static let `default` = RuntimeLaneConfiguration(
        sessionMaxConcurrentRuns: 1,
        globalMainLaneLimit: 4,
        globalSubagentLaneLimit: 8,
        globalCronLaneLimit: 2,
        maxChildrenPerAgent: 5,
        perOwnerSubagentLaneLimit: nil,
        perOwnerSubagentFanoutLimit: nil
    )

    public init(
        sessionMaxConcurrentRuns: Int = 1,
        globalMainLaneLimit: Int = 4,
        globalSubagentLaneLimit: Int = 8,
        globalCronLaneLimit: Int = 2,
        maxChildrenPerAgent: Int = 5,
        perOwnerSubagentLaneLimit: Int? = nil,
        perOwnerSubagentFanoutLimit: Int? = nil
    ) {
        self.sessionMaxConcurrentRuns = max(1, sessionMaxConcurrentRuns)
        self.globalMainLaneLimit = max(1, globalMainLaneLimit)
        self.globalSubagentLaneLimit = max(1, globalSubagentLaneLimit)
        self.globalCronLaneLimit = max(1, globalCronLaneLimit)
        self.maxChildrenPerAgent = min(20, max(1, maxChildrenPerAgent))
        self.perOwnerSubagentLaneLimit = perOwnerSubagentLaneLimit.map { max(1, $0) }
        self.perOwnerSubagentFanoutLimit = perOwnerSubagentFanoutLimit.map { max(1, $0) }
    }

    public func applyingStrictTenancyDefaults(tenancyPolicy: TenancyPolicySettings) -> RuntimeLaneConfiguration {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else { return self }
        var resolved = self
        if resolved.perOwnerSubagentLaneLimit == nil {
            resolved.perOwnerSubagentLaneLimit = max(1, globalSubagentLaneLimit / 2)
        }
        if resolved.perOwnerSubagentFanoutLimit == nil {
            resolved.perOwnerSubagentFanoutLimit = maxChildrenPerAgent * 2
        }
        return resolved
    }
}

enum RuntimeLaneAdmissionError: Error, Sendable, Equatable {
    case sessionLaneBusy(activeRunID: UUID?)
    case globalMainLaneAtCapacity(limit: Int)
    case globalSubagentLaneAtCapacity(limit: Int)
    case globalCronLaneAtCapacity(limit: Int)
    case parentFanoutExceeded(limit: Int)
    case perOwnerSubagentLaneAtCapacity(limit: Int)
    case perOwnerSubagentFanoutExceeded(limit: Int)
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
    private var activeSubagentRunIDsByOwnerScope: [String: Set<UUID>] = [:]
    private var childRunCountByOwnerScope: [String: Int] = [:]

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

    func isRunAdmitted(runID: UUID) -> Bool {
        admissionContextByRunID[runID] != nil
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
            releasePerOwnerSubagentLimits(context)
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
        ownerAccountID: UUID? = nil,
        runID: UUID,
        sessionKey: String = "subagent:anonymous"
    ) -> RuntimeLaneAdmissionError? {
        let context = RunLaneResolver.resolve(
            RunLaneOriginContext(
                sessionKey: sessionKey,
                runID: runID,
                origin: .subagentSpawn,
                parentRunID: parentRunID,
                parentConversationID: parentConversationID,
                ownerAccountID: ownerAccountID
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
            if let ownerError = tryAcquirePerOwnerSubagentLimits(context) {
                return ownerError
            }
            let count = activeRunIDsByGlobalLane[.subagent, default: []].count
            if count >= configuration.globalSubagentLaneLimit {
                return .globalSubagentLaneAtCapacity(limit: configuration.globalSubagentLaneLimit)
            }
            if let fanoutError = tryAcquireSubagentFanout(context) {
                return fanoutError
            }
            commitPerOwnerSubagentLimits(context)
        case .cron:
            let count = activeRunIDsByGlobalLane[.cron, default: []].count
            if count >= configuration.globalCronLaneLimit {
                return .globalCronLaneAtCapacity(limit: configuration.globalCronLaneLimit)
            }
        }
        return nil
    }

    private func tryAcquirePerOwnerSubagentLimits(_ context: RunLaneAdmissionContext) -> RuntimeLaneAdmissionError? {
        guard let ownerScopeKey = ownerScopeKey(for: context.ownerAccountID), !ownerScopeKey.isEmpty else {
            if configuration.perOwnerSubagentLaneLimit != nil || configuration.perOwnerSubagentFanoutLimit != nil {
                return .perOwnerSubagentLaneAtCapacity(limit: configuration.perOwnerSubagentLaneLimit ?? 0)
            }
            return nil
        }
        if let laneLimit = configuration.perOwnerSubagentLaneLimit {
            let ownerCount = activeSubagentRunIDsByOwnerScope[ownerScopeKey, default: []].count
            if ownerCount >= laneLimit {
                return .perOwnerSubagentLaneAtCapacity(limit: laneLimit)
            }
        }
        if let fanoutLimit = configuration.perOwnerSubagentFanoutLimit {
            let fanoutCount = childRunCountByOwnerScope[ownerScopeKey, default: 0]
            if fanoutCount >= fanoutLimit {
                return .perOwnerSubagentFanoutExceeded(limit: fanoutLimit)
            }
        }
        return nil
    }

    private func commitPerOwnerSubagentLimits(_ context: RunLaneAdmissionContext) {
        guard let ownerScopeKey = ownerScopeKey(for: context.ownerAccountID), !ownerScopeKey.isEmpty else {
            return
        }
        activeSubagentRunIDsByOwnerScope[ownerScopeKey, default: []].insert(context.runID)
        childRunCountByOwnerScope[ownerScopeKey] = childRunCountByOwnerScope[ownerScopeKey, default: 0] + 1
    }

    private func releasePerOwnerSubagentLimits(_ context: RunLaneAdmissionContext) {
        guard let ownerScopeKey = ownerScopeKey(for: context.ownerAccountID), !ownerScopeKey.isEmpty else {
            return
        }
        if var runs = activeSubagentRunIDsByOwnerScope[ownerScopeKey] {
            runs.remove(context.runID)
            if runs.isEmpty {
                activeSubagentRunIDsByOwnerScope.removeValue(forKey: ownerScopeKey)
            } else {
                activeSubagentRunIDsByOwnerScope[ownerScopeKey] = runs
            }
        }
        let fanoutCount = childRunCountByOwnerScope[ownerScopeKey, default: 0]
        if fanoutCount <= 1 {
            childRunCountByOwnerScope.removeValue(forKey: ownerScopeKey)
        } else {
            childRunCountByOwnerScope[ownerScopeKey] = fanoutCount - 1
        }
    }

    private func ownerScopeKey(for ownerAccountID: UUID?) -> String? {
        guard let ownerAccountID else { return nil }
        return AgentMemoryPathResolver.ownerSegment(ownerAccountID)
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
