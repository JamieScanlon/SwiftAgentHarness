import Foundation

public struct TriggerCorrelation: Codable, Sendable, Equatable {
    public var rootId: String
    public var parentTriggerId: String?
    public var correlationId: String
    public var followUpKind: String?

    public init(
        rootId: String,
        parentTriggerId: String? = nil,
        correlationId: String,
        followUpKind: String? = nil
    ) {
        self.rootId = rootId
        self.parentTriggerId = parentTriggerId
        self.correlationId = correlationId
        self.followUpKind = followUpKind
    }

    public static func root(triggerID: String) -> TriggerCorrelation {
        TriggerCorrelation(
            rootId: triggerID,
            parentTriggerId: nil,
            correlationId: triggerID
        )
    }

    public static func child(parent: HarnessTrigger, followUpKind: String? = nil) -> TriggerCorrelation {
        let parentCorrelation = parent.effectiveCorrelation()
        return TriggerCorrelation(
            rootId: parentCorrelation.rootId,
            parentTriggerId: parent.id,
            correlationId: parentCorrelation.correlationId,
            followUpKind: followUpKind
        )
    }

    public static func fromPayload(
        rootId: String?,
        parentTriggerId: String?,
        correlationId: String?,
        followUpKind: String? = nil,
        fallbackTriggerID: String
    ) -> TriggerCorrelation {
        if let correlationId, let rootId {
            return TriggerCorrelation(
                rootId: rootId,
                parentTriggerId: parentTriggerId,
                correlationId: correlationId,
                followUpKind: followUpKind
            )
        }
        return root(triggerID: fallbackTriggerID)
    }

    public static func explicit(
        rootId: String?,
        parentTriggerId: String?,
        correlationId: String?,
        fallbackTriggerID: String
    ) -> TriggerCorrelation? {
        guard rootId != nil || parentTriggerId != nil || correlationId != nil else {
            return nil
        }
        let resolvedRoot = rootId ?? correlationId ?? fallbackTriggerID
        let resolvedCorrelation = correlationId ?? resolvedRoot
        return TriggerCorrelation(
            rootId: resolvedRoot,
            parentTriggerId: parentTriggerId,
            correlationId: resolvedCorrelation
        )
    }
}

extension HarnessTrigger {
    public func effectiveCorrelation() -> TriggerCorrelation {
        correlation ?? .root(triggerID: id)
    }

    public func withRootCorrelation() -> HarnessTrigger {
        var updated = self
        if updated.correlation == nil {
            updated.correlation = .root(triggerID: id)
        }
        return updated
    }

    public func applyingCorrelation(_ correlation: TriggerCorrelation?) -> HarnessTrigger {
        var updated = self
        updated.correlation = correlation
        return updated
    }
}
