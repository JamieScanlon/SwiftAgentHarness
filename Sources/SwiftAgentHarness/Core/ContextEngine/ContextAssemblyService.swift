//
//  Transform timeout, metadata construction, and turn assembly wiring.
//

import Foundation
import SwiftAgentKit

enum ContextAssemblyService {
    /// `POST .../preview-context-compaction` can run multi-pass compaction on huge middles.
    static let contextCompactionPreviewTransformTaskTimeoutSeconds: Double = 86_400

    enum TransformTimeoutError: Error {
        case timedOut
    }

    static func conversationTransformMetadata(for conversation: ModelConversation) -> ConversationTransformMetadata {
        let routing = conversation.routingPrefs?.explicitToolPolicy
        return ConversationTransformMetadata(
            conversationID: conversation.id,
            ownerAccountID: conversation.ownerAccountID,
            modelID: conversation.model.id.uuidString,
            modelName: conversation.model.modelName,
            interactionMode: conversation.interactionMode,
            routingPolicyTools: routing?.tools.sorted() ?? [],
            routingPolicySkills: routing?.skills.sorted() ?? [],
            thinkingConfig: .disabled,
            metadata: conversation.metadata
        )
    }

    static func runTransformWithTimeout<T: Sendable>(
        transformTimeoutSeconds: Double,
        timeoutSecondsOverride: Double? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds = timeoutSecondsOverride ?? transformTimeoutSeconds
        let timeoutNanoseconds = UInt64(max(1.0, timeoutSeconds) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw TransformTimeoutError.timedOut
            }
            guard let first = try await group.next() else {
                throw TransformTimeoutError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

}

private extension ConversationExplicitToolPolicy {
    var tools: [String] {
        switch self {
        case .denylist(let tools, _), .allowlist(let tools, _):
            return tools
        }
    }

    var skills: [String] {
        switch self {
        case .denylist(_, let skills), .allowlist(_, let skills):
            return skills
        }
    }
}
