import Foundation

public enum RuntimeGlobalLaneKind: String, Sendable, Equatable, Hashable {
    case main
    case subagent
    case cron
}

public enum RunLaneOriginKind: Sendable, Equatable {
    case interactive
    case trigger(TriggerSource)
    case subagentSpawn
    case pendingCompletionResume
}

public struct RunLaneOriginContext: Sendable, Equatable {
    public let sessionKey: String
    public let runID: UUID
    public let origin: RunLaneOriginKind
    public let parentRunID: UUID?
    public let parentConversationID: UUID?
    public let ownerAccountID: UUID?

    public init(
        sessionKey: String,
        runID: UUID,
        origin: RunLaneOriginKind,
        parentRunID: UUID? = nil,
        parentConversationID: UUID? = nil,
        ownerAccountID: UUID? = nil
    ) {
        self.sessionKey = sessionKey
        self.runID = runID
        self.origin = origin
        self.parentRunID = parentRunID
        self.parentConversationID = parentConversationID
        self.ownerAccountID = ownerAccountID
    }
}

public struct RunLaneAdmissionContext: Sendable, Equatable {
    public let sessionKey: String
    public let runID: UUID
    public let globalLane: RuntimeGlobalLaneKind
    public let parentRunID: UUID?
    public let parentConversationID: UUID?
    public let ownerAccountID: UUID?
    public let originSurface: String?

    public init(
        sessionKey: String,
        runID: UUID,
        globalLane: RuntimeGlobalLaneKind,
        parentRunID: UUID? = nil,
        parentConversationID: UUID? = nil,
        ownerAccountID: UUID? = nil,
        originSurface: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.runID = runID
        self.globalLane = globalLane
        self.parentRunID = parentRunID
        self.parentConversationID = parentConversationID
        self.ownerAccountID = ownerAccountID
        self.originSurface = originSurface
    }
}

enum RunLaneResolver {
    static func resolve(_ context: RunLaneOriginContext) -> RunLaneAdmissionContext {
        let globalLane = resolveGlobalLane(origin: context.origin)
        return RunLaneAdmissionContext(
            sessionKey: context.sessionKey,
            runID: context.runID,
            globalLane: globalLane,
            parentRunID: context.parentRunID,
            parentConversationID: context.parentConversationID,
            ownerAccountID: context.ownerAccountID,
            originSurface: originSurfaceLabel(for: context.origin)
        )
    }

    static func runLaneOrigin(originSurface: String?) -> RunLaneOriginKind {
        guard let originSurface, !originSurface.isEmpty else { return .interactive }
        if originSurface == TriggerSource.cron.rawValue {
            return .trigger(.cron)
        }
        if let source = TriggerSource(rawValue: originSurface) {
            return .trigger(source)
        }
        return .interactive
    }

    private static func resolveGlobalLane(origin: RunLaneOriginKind) -> RuntimeGlobalLaneKind {
        switch origin {
        case .subagentSpawn:
            return .subagent
        case .trigger(.cron):
            return .cron
        case .interactive, .pendingCompletionResume, .trigger:
            return .main
        }
    }

    private static func originSurfaceLabel(for origin: RunLaneOriginKind) -> String? {
        switch origin {
        case .interactive:
            return "interactive"
        case .trigger(let source):
            return source.rawValue
        case .subagentSpawn:
            return "subagent"
        case .pendingCompletionResume:
            return "pending_completion_resume"
        }
    }
}
