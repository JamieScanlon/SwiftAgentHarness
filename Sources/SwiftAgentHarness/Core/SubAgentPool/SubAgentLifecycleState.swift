import Foundation

struct SubAgentLifecycleState {
    struct TransportContext: Sendable, Equatable {
        var transportKind: SubAgentTransportKind
        var sessionHandleID: String
        var completionHandleID: String?
    }

    private var entriesByParentConversationID: [UUID: [SubAgentLifecycleEntryPayload]] = [:]
    private var startedAtByLifecycleID: [String: Date] = [:]
    private var pathSegmentsByLifecycleID: [String: [String]] = [:]
    private var rootConversationIDByLifecycleID: [String: UUID] = [:]
    private var childCountByParentPathKey: [String: Int] = [:]
    private var transportContextByLifecycleID: [String: TransportContext] = [:]

    mutating func reset() {
        entriesByParentConversationID = [:]
        startedAtByLifecycleID = [:]
        pathSegmentsByLifecycleID = [:]
        rootConversationIDByLifecycleID = [:]
        childCountByParentPathKey = [:]
        transportContextByLifecycleID = [:]
    }

    func entries(parentConversationID: UUID) -> [SubAgentLifecycleEntryPayload] {
        entriesByParentConversationID[parentConversationID] ?? []
    }

    func allEntries() -> [SubAgentLifecycleEntryPayload] {
        entriesByParentConversationID.values.flatMap { $0 }
    }

    /// Non-terminal invocations whose spawned child is `childConversationID`.
    ///
    /// `awaitingApproval` is deliberately excluded: a paused invocation is expected to resume, so
    /// ending its lane on a turn boundary would under-count concurrency rather than leak it.
    func activeEntries(childConversationID: UUID) -> [SubAgentLifecycleEntryPayload] {
        let active: Set<SubAgentLifecyclePhase> = [.queued, .dispatching, .running, .completing]
        return allEntries().filter {
            $0.childConversationID == childConversationID && active.contains($0.phase)
        }
    }

    func startedAt(lifecycleID: String) -> Date? {
        startedAtByLifecycleID[lifecycleID]
    }

    func rootConversationID(lifecycleID: String) -> UUID? {
        rootConversationIDByLifecycleID[lifecycleID]
    }

    func pathSegments(lifecycleID: String) -> [String]? {
        pathSegmentsByLifecycleID[lifecycleID]
    }

    func transportContext(lifecycleID: String) -> TransportContext? {
        transportContextByLifecycleID[lifecycleID]
    }

    mutating func setTransportContext(lifecycleID: String, context: TransportContext) {
        transportContextByLifecycleID[lifecycleID] = context
    }

    func siblingCounterKey(rootConversationID: UUID, parentPathSegments: [String]) -> String {
        "\(rootConversationID.uuidString.lowercased())|\(parentPathSegments.joined(separator: "/"))"
    }

    mutating func registerRestoredLifecycle(
        lifecycleID: String,
        pathSegments: [String],
        rootConversationID: UUID,
        updatedAt: Date,
        startedAt: Date
    ) {
        if !pathSegments.isEmpty {
            pathSegmentsByLifecycleID[lifecycleID] = pathSegments
            rootConversationIDByLifecycleID[lifecycleID] = rootConversationID
            let parentPathSegments = Array(pathSegments.dropLast())
            let key = siblingCounterKey(rootConversationID: rootConversationID, parentPathSegments: parentPathSegments)
            if let last = pathSegments.last,
               let ordinal = Int(last.replacingOccurrences(of: "agent-", with: "")) {
                childCountByParentPathKey[key] = max(childCountByParentPathKey[key] ?? 0, ordinal + 1)
            } else {
                childCountByParentPathKey[key] = max(childCountByParentPathKey[key] ?? 0, 1)
            }
        }
        startedAtByLifecycleID[lifecycleID] = min(startedAtByLifecycleID[lifecycleID] ?? updatedAt, startedAt)
    }

    mutating func assignPathSegments(
        lifecycleID: String,
        rootConversationID: UUID,
        parentPathSegments: [String]
    ) -> [String] {
        if let existing = pathSegmentsByLifecycleID[lifecycleID] {
            return existing
        }
        let key = siblingCounterKey(rootConversationID: rootConversationID, parentPathSegments: parentPathSegments)
        let ordinal = childCountByParentPathKey[key] ?? 0
        childCountByParentPathKey[key] = ordinal + 1
        let path = parentPathSegments + ["agent-\(ordinal)"]
        pathSegmentsByLifecycleID[lifecycleID] = path
        rootConversationIDByLifecycleID[lifecycleID] = rootConversationID
        return path
    }

    mutating func upsert(
        parentConversationID: UUID,
        entry: SubAgentLifecycleEntryPayload
    ) {
        var entries = entriesByParentConversationID[parentConversationID] ?? []
        if let idx = entries.firstIndex(where: { $0.lifecycleID == entry.lifecycleID }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.lifecycleID < $1.lifecycleID }
        entriesByParentConversationID[parentConversationID] = entries
        if startedAtByLifecycleID[entry.lifecycleID] == nil {
            startedAtByLifecycleID[entry.lifecycleID] = Date()
        }
        if entry.phase == .done || entry.phase == .failed {
            startedAtByLifecycleID.removeValue(forKey: entry.lifecycleID)
            transportContextByLifecycleID.removeValue(forKey: entry.lifecycleID)
        }
    }

    func snapshot(parentConversationID: UUID) -> SubAgentLifecycleTopicPayload {
        SubAgentLifecycleTopicPayload(
            parentConversationID: parentConversationID,
            entries: entries(parentConversationID: parentConversationID)
        )
    }

    func snapshot(conversationID: UUID, pathSegments branchPath: [String]) -> SubAgentLifecycleTopicPayload {
        let entries = allEntries()
            .filter { entry in
                guard rootConversationID(lifecycleID: entry.lifecycleID) == conversationID,
                      let entryPath = pathSegments(lifecycleID: entry.lifecycleID)
                else { return false }
                return entryPath.starts(with: branchPath)
            }
            .sorted { $0.lifecycleID < $1.lifecycleID }
        return SubAgentLifecycleTopicPayload(parentConversationID: conversationID, entries: entries)
    }

    func listActiveInvocations(parentConversationID: UUID) -> [ActiveSubAgentInvocationInfo] {
        let activePhases: Set<SubAgentLifecyclePhase> = [.queued, .dispatching, .running, .awaitingApproval, .completing]
        return entries(parentConversationID: parentConversationID)
            .filter { activePhases.contains($0.phase) }
            .map { entry in
                ActiveSubAgentInvocationInfo(
                    lifecycleID: entry.lifecycleID,
                    parentConversationID: entry.parentConversationID,
                    childConversationID: entry.childConversationID,
                    delegateToolName: entry.delegateToolName,
                    transportKind: transportContext(lifecycleID: entry.lifecycleID)?.transportKind.rawValue,
                    asyncHandleID: entry.asyncHandleID,
                    phase: entry.phase,
                    startedAt: startedAt(lifecycleID: entry.lifecycleID),
                    updatedAt: entry.updatedAt,
                    error: entry.error
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func entry(parentConversationID: UUID, lifecycleID: String) -> SubAgentLifecycleEntryPayload? {
        entries(parentConversationID: parentConversationID)
            .first(where: { $0.lifecycleID == lifecycleID })
    }

    func entry(parentConversationID: UUID, matching delegateHandleID: String) -> SubAgentLifecycleEntryPayload? {
        entries(parentConversationID: parentConversationID)
            .first(where: { $0.asyncHandleID == delegateHandleID || $0.lifecycleID == delegateHandleID })
    }
}
