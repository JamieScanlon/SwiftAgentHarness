import Foundation
import SwiftAgentKit
import SwiftAgentKitA2A

enum SubAgentA2ADelegateStreamMapping {
    static func map(
        event: A2ADelegateStreamEvent,
        session: RemoteTransportSession
    ) -> SubAgentDelegateEvent? {
        let base = SubAgentDelegateEvent(
            lifecycleID: session.correlation.lifecycleID,
            parentConversationID: session.parentConversationID,
            delegateToolName: session.delegateToolName,
            asyncHandleID: session.correlation.completionHandleID,
            phase: .running,
            eventTrustLevel: SubAgentTrustLevel.knownParty.rawValue,
            defaultTrustLevel: session.defaultTrustLevel,
            permissionPolicy: session.permissionPolicy,
            updatedAt: Date()
        )
        switch event {
        case .connecting:
            var mapped = base
            mapped.phase = .dispatching
            return mapped
        case let .taskStarted(taskID, _):
            var mapped = base
            mapped.phase = .running
            mapped.toolCallID = session.correlation.completionHandleID
            _ = taskID
            return mapped
        case let .statusUpdate(_, state, final):
            var mapped = base
            switch state {
            case .completed where final:
                mapped.phase = .completing
            case .failed, .rejected, .canceled:
                mapped.phase = .failed
                mapped.error = "a2a_task_\(state.rawValue)"
            default:
                mapped.phase = .running
            }
            return mapped
        case .artifactChunk, .messageChunk:
            return base
        case let .completed(completion):
            var mapped = base
            mapped.phase = .done
            mapped.completionSource = completion.content
            mapped.completionUsage = SubAgentDelegateCompletionUsageMapping.from(llmMetadata: completion.metadata)
            return mapped
        case let .failed(failure):
            var mapped = base
            mapped.phase = .failed
            mapped.error = failure.error
            return mapped
        }
    }

    static func instructions(from request: SubAgentLaunchPlan) -> String {
        let candidates = [
            request.request.taskDescription,
            request.request.prompt,
            request.request.topic,
            request.request.description,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Complete the delegated task."
    }

    static func toolCall(from request: SubAgentTransportInvocationRequest, lifecycleID: String) -> ToolCall {
        let toolName = request.registryEntry.delegateToolName
        let instructions = instructions(from: request.launchPlan)
        let toolCallID = request.launchPlan.asyncHandleID ?? lifecycleID
        return ToolCall(
            name: toolName,
            arguments: .object(["instructions": .string(instructions)]),
            id: toolCallID
        )
    }
}
