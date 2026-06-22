import Foundation

public struct RuntimeLaneConfiguration: Sendable, Equatable {
    public var sessionMaxConcurrentRuns: Int
    public var globalMainLaneLimit: Int
    public var globalSubagentLaneLimit: Int
    public var maxChildrenPerAgent: Int

    public static let `default` = RuntimeLaneConfiguration(
        sessionMaxConcurrentRuns: 1,
        globalMainLaneLimit: 4,
        globalSubagentLaneLimit: 8,
        maxChildrenPerAgent: 5
    )

    public init(
        sessionMaxConcurrentRuns: Int = 1,
        globalMainLaneLimit: Int = 4,
        globalSubagentLaneLimit: Int = 8,
        maxChildrenPerAgent: Int = 5
    ) {
        self.sessionMaxConcurrentRuns = max(1, sessionMaxConcurrentRuns)
        self.globalMainLaneLimit = max(1, globalMainLaneLimit)
        self.globalSubagentLaneLimit = max(1, globalSubagentLaneLimit)
        self.maxChildrenPerAgent = min(20, max(1, maxChildrenPerAgent))
    }
}

enum RuntimeLaneAdmissionError: Error, Sendable, Equatable {
    case sessionLaneBusy(activeRunID: UUID?)
    case globalMainLaneAtCapacity(limit: Int)
    case globalSubagentLaneAtCapacity(limit: Int)
    case parentFanoutExceeded(limit: Int)
}

actor RuntimeLaneCoordinator {
    private let configuration: RuntimeLaneConfiguration
    private var activeMainRunsBySessionKey: [String: UUID] = [:]
    private var activeMainRunIDs: Set<UUID> = []
    private var activeSubagentRunIDs: Set<UUID> = []
    private var childRunParentIdentityByRunID: [UUID: String] = [:]
    private var childRunCountByParentIdentity: [String: Int] = [:]

    init(configuration: RuntimeLaneConfiguration = .default) {
        self.configuration = configuration
    }

    func tryAcquireMainRun(sessionKey: String, runID: UUID) -> RuntimeLaneAdmissionError? {
        if let active = activeMainRunsBySessionKey[sessionKey], active != runID {
            return .sessionLaneBusy(activeRunID: active)
        }
        if activeMainRunIDs.count >= configuration.globalMainLaneLimit {
            return .globalMainLaneAtCapacity(limit: configuration.globalMainLaneLimit)
        }
        activeMainRunsBySessionKey[sessionKey] = runID
        activeMainRunIDs.insert(runID)
        return nil
    }

    func releaseMainRun(sessionKey: String, runID: UUID) {
        if activeMainRunsBySessionKey[sessionKey] == runID {
            activeMainRunsBySessionKey.removeValue(forKey: sessionKey)
        }
        activeMainRunIDs.remove(runID)
        childRunCountByParentIdentity.removeValue(forKey: runID.uuidString.lowercased())
    }

    func tryAcquireSubagentRun(
        parentRunID: UUID?,
        parentConversationID: UUID? = nil,
        runID: UUID
    ) -> RuntimeLaneAdmissionError? {
        if activeSubagentRunIDs.count >= configuration.globalSubagentLaneLimit {
            return .globalSubagentLaneAtCapacity(limit: configuration.globalSubagentLaneLimit)
        }
        let parentIdentity: String? = if let parentConversationID {
            parentConversationID.uuidString.lowercased()
        } else if let parentRunID {
            parentRunID.uuidString.lowercased()
        } else {
            nil
        }
        if let parentIdentity {
            let childCount = childRunCountByParentIdentity[parentIdentity, default: 0]
            if childCount >= configuration.maxChildrenPerAgent {
                return .parentFanoutExceeded(limit: configuration.maxChildrenPerAgent)
            }
            childRunParentIdentityByRunID[runID] = parentIdentity
            childRunCountByParentIdentity[parentIdentity] = childCount + 1
        }
        activeSubagentRunIDs.insert(runID)
        return nil
    }

    func releaseSubagentRun(runID: UUID) {
        activeSubagentRunIDs.remove(runID)
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
