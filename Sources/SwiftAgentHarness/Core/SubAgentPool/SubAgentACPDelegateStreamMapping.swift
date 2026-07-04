import Foundation
import SwiftAgentKit
import SwiftAgentKitACP

struct SubAgentACPDelegateStreamMapper {
    private var accumulatedUsage: DelegateCompletionUsagePayload?

    mutating func map(
        event: ACPDelegateStreamEvent,
        session: RemoteTransportSession
    ) -> SubAgentDelegateEvent? {
        let base = SubAgentDelegateEvent(
            lifecycleID: session.correlation.lifecycleID,
            parentConversationID: session.parentConversationID,
            delegateToolName: session.delegateToolName,
            asyncHandleID: session.correlation.completionHandleID,
            phase: .running,
            eventTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            defaultTrustLevel: session.defaultTrustLevel,
            permissionPolicy: session.permissionPolicy,
            updatedAt: Date()
        )
        switch event {
        case .connecting:
            var mapped = base
            mapped.phase = .dispatching
            return mapped
        case .messageChunk, .userMessageChunk, .thoughtChunk, .availableCommandsUpdate, .plan,
             .toolCall, .toolCallUpdate, .sessionInfoUpdate, .currentModeUpdate,
             .configOptionUpdate:
            return base
        case let .usageUpdate(used, size, cost):
            if let update = SubAgentDelegateCompletionUsageMapping.from(used: used, size: size, cost: cost) {
                accumulatedUsage = SubAgentDelegateCompletionUsageMapping.merging(accumulatedUsage, with: update)
            }
            return base
        case let .completed(content, _, sessionID):
            var mapped = base
            mapped.phase = .done
            mapped.completionSource = content
            mapped.completionUsage = accumulatedUsage
            _ = sessionID
            return mapped
        case let .failed(error, sessionID):
            var mapped = base
            mapped.phase = .failed
            mapped.error = error
            _ = sessionID
            return mapped
        }
    }
}

enum SubAgentACPDelegateStreamMapping {
    static func instructions(from request: SubAgentLaunchPlan) -> String {
        SubAgentA2ADelegateStreamMapping.instructions(from: request)
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
