import EasyJSON
import Foundation

/// Explicit per-run conversation identity — not the foreground selection singleton.
public struct ConversationScope: Sendable, Equatable {
    public let selfID: UUID
    public let parentID: UUID?
    public let rootID: UUID
    public let lineageKind: ConversationLineageKind
    public let origin: ConversationOrigin
    public let depth: Int

    public init(
        selfID: UUID,
        parentID: UUID?,
        rootID: UUID,
        lineageKind: ConversationLineageKind,
        origin: ConversationOrigin,
        depth: Int = 0
    ) {
        self.selfID = selfID
        self.parentID = parentID
        self.rootID = rootID
        self.lineageKind = lineageKind
        self.origin = origin
        self.depth = max(0, depth)
    }

    public var isSubAgent: Bool { lineageKind == .subAgent }

    @TaskLocal public static var current: ConversationScope?

    public static func withCurrent<T>(
        _ scope: ConversationScope,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(scope, operation: operation)
    }

    public static func resolvedConversationID(fallback: UUID? = nil) -> UUID? {
        current?.selfID ?? fallback
    }

    public static func subAgentDepth(from metadata: JSON?) -> Int {
        guard case .object(let object) = metadata,
              let raw = object["subAgentDepth"]?.literalValue else {
            return 0
        }
        if let d = raw as? Double { return max(0, Int(d)) }
        if let i = raw as? Int { return max(0, i) }
        return 0
    }

    public static func subAgentRootConversationID(from metadata: JSON?, selfID: UUID) -> UUID {
        guard case .object(let object) = metadata,
              let raw = object["subAgentRootConversationID"]?.literalValue as? String,
              let uuid = UUID(uuidString: raw) else {
            return selfID
        }
        return uuid
    }
}
