import Foundation
import Logging

actor RuntimeTurnStreamTransportAdapter {
    private let publish: @Sendable (RuntimeLifecycleEventPayload) async -> Void
    private let logger: Logger?
    private var completedToolNames: [String] = []

    init(
        logger: Logger? = nil,
        publish: @escaping @Sendable (RuntimeLifecycleEventPayload) async -> Void
    ) {
        self.logger = logger
        self.publish = publish
    }

    func consume(_ event: RuntimeLifecycleEventPayload) async {
        if event.name == .toolCallCompleted,
           let toolName = event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolName.isEmpty {
            completedToolNames.append(toolName)
        }
        if event.name == .loopIterationCompleted {
            await publishBatchSummaryIfNeeded(from: event)
        }
        logger?.debug(
            "[RuntimeTurnStreamTransportAdapter] publish runtimeLifecycle name=\(event.name.rawValue) conversationID=\(event.conversationID.uuidString) runID=\(event.runID?.uuidString ?? "nil") iteration=\(event.iteration.map(String.init) ?? "nil") toolName=\(event.toolName ?? "nil")"
        )
        await publish(event)
    }

    private func publishBatchSummaryIfNeeded(from iterationEvent: RuntimeLifecycleEventPayload) async {
        guard !completedToolNames.isEmpty else { return }
        let summaryText = ToolUsageSummaryLabelFormatter.templateLabel(toolNames: completedToolNames)
        guard !summaryText.isEmpty else {
            completedToolNames.removeAll(keepingCapacity: true)
            return
        }
        let uniqueToolNames = Array(Set(completedToolNames)).sorted()
        let payload = RuntimeLifecycleEventPayload(
            name: .toolUsageSummary,
            conversationID: iterationEvent.conversationID,
            runID: iterationEvent.runID,
            iteration: iterationEvent.iteration,
            toolCount: completedToolNames.count,
            toolNames: uniqueToolNames,
            summaryText: summaryText,
            source: "runtime.templateLabel"
        )
        logger?.debug(
            "[RuntimeTurnStreamTransportAdapter] publish runtimeLifecycle summary conversationID=\(iterationEvent.conversationID.uuidString) runID=\(iterationEvent.runID?.uuidString ?? "nil") iteration=\(iterationEvent.iteration.map(String.init) ?? "nil") completedToolCalls=\(completedToolNames.count) uniqueTools=\(uniqueToolNames.count) summaryText=\(summaryText)"
        )
        completedToolNames.removeAll(keepingCapacity: true)
        await publish(payload)
    }
}
