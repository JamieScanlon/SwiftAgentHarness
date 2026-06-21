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
        logger?.debug(
            "[RuntimeTurnStreamTransportAdapter] publish runtimeLifecycle name=\(event.name.rawValue) conversationID=\(event.conversationID.uuidString) runID=\(event.runID?.uuidString ?? "nil") iteration=\(event.iteration.map(String.init) ?? "nil") toolName=\(event.toolName ?? "nil")"
        )
        await publish(event)
    }

    func publishToolUsageSummaryIfNeeded(
        conversationID: UUID,
        runID: UUID?
    ) async {
        guard !completedToolNames.isEmpty else { return }
        let uniqueToolNames = Array(Set(completedToolNames)).sorted()
        let payload = RuntimeLifecycleEventPayload(
            name: .toolUsageSummary,
            conversationID: conversationID,
            runID: runID,
            toolCount: completedToolNames.count,
            toolNames: uniqueToolNames,
            summaryText: "Completed \(completedToolNames.count) tool call(s) across \(uniqueToolNames.count) tool(s).",
            source: "runtime.summary"
        )
        logger?.debug(
            "[RuntimeTurnStreamTransportAdapter] publish runtimeLifecycle summary conversationID=\(conversationID.uuidString) runID=\(runID?.uuidString ?? "nil") completedToolCalls=\(completedToolNames.count) uniqueTools=\(uniqueToolNames.count)"
        )
        await publish(payload)
    }
}
