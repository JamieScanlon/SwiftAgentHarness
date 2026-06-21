import Foundation

enum PublishingContractValidator {
    static func validateConversationEventPayload(_ payload: ConversationTopicEventPayload) -> [String] {
        var issues: [String] = []
        switch payload.semanticKind {
        case .messagesRefresh:
            guard let json = payload.jsonUTF8 else {
                issues.append("messagesRefresh requires jsonUTF8")
                return issues
            }
            guard let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data)
            else {
                issues.append("messagesRefresh jsonUTF8 must be valid JSON")
                return issues
            }
            if raw is [Any] {
                // array form of message rows
            } else if let obj = raw as? [String: Any] {
                let allowed = Set(["messages", "latestTranscriptSequence"])
                guard Set(obj.keys).isSubset(of: allowed) else {
                    let extra = Set(obj.keys).subtracting(allowed)
                    issues.append("messagesRefresh envelope has unexpected keys: \(extra.sorted().joined(separator: ", "))")
                    return issues
                }
                guard let msg = obj["messages"] as? [Any] else {
                    issues.append("messagesRefresh object form requires messages array")
                    return issues
                }
                for item in msg where !(item is [String: Any]) {
                    issues.append("messagesRefresh messages entries must be objects")
                    return issues
                }
                if let seq = obj["latestTranscriptSequence"] {
                    guard jsonInteger(seq) != nil else {
                        issues.append("latestTranscriptSequence must be an integer when present")
                        return issues
                    }
                }
            } else {
                issues.append("messagesRefresh jsonUTF8 must be a JSON array or messages envelope object")
                return issues
            }
        case .contentDelta:
            guard decode(payload.jsonUTF8, as: ModelContentDeltaWire.self) != nil else {
                issues.append("contentDelta requires ModelContentDeltaWire jsonUTF8")
                return issues
            }
        case .surfaceIntent:
            guard decode(payload.jsonUTF8, as: ClientSurfaceIntent.self) != nil else {
                issues.append("surfaceIntent requires ClientSurfaceIntent jsonUTF8")
                return issues
            }
        case .streamDone:
            if payload.jsonUTF8 != nil {
                issues.append("streamDone must not set jsonUTF8")
            }
        case .modelLifecycle:
            guard decode(payload.jsonUTF8, as: ModelStatePayload.self) != nil else {
                issues.append("modelLifecycle requires ModelStatePayload jsonUTF8")
                return issues
            }
        case .runtimeLifecycle:
            guard let lifecycle = decode(payload.jsonUTF8, as: RuntimeLifecycleEventPayload.self) else {
                issues.append("runtimeLifecycle requires RuntimeLifecycleEventPayload jsonUTF8")
                return issues
            }
            if lifecycle.schemaVersion != RuntimeLifecycleEventPayload.schemaVersionV1 {
                issues.append("runtimeLifecycle schemaVersion must be \(RuntimeLifecycleEventPayload.schemaVersionV1)")
            }
            if let iteration = lifecycle.iteration, iteration < 1 {
                issues.append("runtimeLifecycle iteration must be >= 1 when present")
            }
            if let originTrustLevel = lifecycle.originTrustLevel,
               originTrustLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("runtimeLifecycle originTrustLevel must be non-empty when present")
            }
            if lifecycle.name == .toolCallStarted
                || lifecycle.name == .toolCallCompleted
                || lifecycle.name == .toolCompletionAnnounced
                || lifecycle.name == .toolApprovalRequired
                || lifecycle.name == .toolApprovalResolved
                || lifecycle.name == .toolElevatedExecuted
            {
                if (lifecycle.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool events require non-empty toolName")
                }
            }
            if lifecycle.name == .toolCallStarted
                || lifecycle.name == .toolCallCompleted
                || lifecycle.name == .toolCompletionAnnounced
            {
                if (lifecycle.toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool call milestones require non-empty toolCallID")
                }
            }
            if let promptTokens = lifecycle.usage?.promptTokens, promptTokens < 0 {
                issues.append("runtimeLifecycle usage.promptTokens must be >= 0")
            }
            if let completionTokens = lifecycle.usage?.completionTokens, completionTokens < 0 {
                issues.append("runtimeLifecycle usage.completionTokens must be >= 0")
            }
            if let totalTokens = lifecycle.usage?.totalTokens, totalTokens < 0 {
                issues.append("runtimeLifecycle usage.totalTokens must be >= 0")
            }
            if let costUSD = lifecycle.usage?.costUSD, costUSD < 0 {
                issues.append("runtimeLifecycle usage.costUSD must be >= 0")
            }
            if let argumentByteCount = lifecycle.argumentByteCount, argumentByteCount < 0 {
                issues.append("runtimeLifecycle argumentByteCount must be >= 0")
            }
            if let resultByteCount = lifecycle.resultByteCount, resultByteCount < 0 {
                issues.append("runtimeLifecycle resultByteCount must be >= 0")
            }
            if lifecycle.argumentDigest != nil
                && (lifecycle.argumentRedaction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                issues.append("runtimeLifecycle argumentDigest requires non-empty argumentRedaction")
            }
            if lifecycle.resultDigest != nil
                && (lifecycle.resultRedaction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                issues.append("runtimeLifecycle resultDigest requires non-empty resultRedaction")
            }
            if let kind = lifecycle.executionEnvironmentKind,
               kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("runtimeLifecycle executionEnvironmentKind must be non-empty when present")
            }
            if let adapterID = lifecycle.executionEnvironmentAdapterID,
               !adapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               lifecycle.executionEnvironmentKind == nil {
                issues.append("runtimeLifecycle executionEnvironmentAdapterID requires executionEnvironmentKind")
            }
            if let isolation = lifecycle.executionIsolationLevel,
               !isolation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               lifecycle.executionEnvironmentKind == nil {
                issues.append("runtimeLifecycle executionIsolationLevel requires executionEnvironmentKind")
            }
            if lifecycle.name == .toolApprovalRequired {
                if lifecycle.approvalState != .pending {
                    issues.append("runtimeLifecycle tool.approvalRequired must set approvalState=pending")
                }
                if (lifecycle.policyReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalRequired requires non-empty policyReason")
                }
                if lifecycle.approvalRoute == nil {
                    issues.append("runtimeLifecycle tool.approvalRequired requires approvalRoute")
                }
                if (lifecycle.approvalTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalRequired requires non-empty approvalTitle")
                }
                if (lifecycle.approvalDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalRequired requires non-empty approvalDescription")
                }
                if (lifecycle.approvalSeverity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalRequired requires non-empty approvalSeverity")
                }
                if (lifecycle.approvalTimeoutMs ?? 0) <= 0 {
                    issues.append("runtimeLifecycle tool.approvalRequired requires approvalTimeoutMs > 0")
                }
                if (lifecycle.approvalTimeoutBehavior?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalRequired requires non-empty approvalTimeoutBehavior")
                }
            }
            if lifecycle.name == .toolApprovalResolved {
                if lifecycle.approvalState != .approved && lifecycle.approvalState != .denied {
                    issues.append("runtimeLifecycle tool.approvalResolved must set approvalState=approved|denied")
                }
                if (lifecycle.approvalSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalResolved requires non-empty approvalSource")
                }
                if lifecycle.approvalRoute == nil {
                    issues.append("runtimeLifecycle tool.approvalResolved requires approvalRoute")
                }
                if (lifecycle.approvalResolutionKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.approvalResolved requires non-empty approvalResolutionKind")
                }
            }
            if lifecycle.name == .toolElevatedExecuted {
                if (lifecycle.policyReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.elevatedExecuted requires non-empty policyReason")
                }
            }
            if lifecycle.name == .toolUsageSummary {
                if (lifecycle.toolCount ?? 0) <= 0 {
                    issues.append("runtimeLifecycle tool.usageSummary requires toolCount > 0")
                }
                if (lifecycle.toolNames?.isEmpty ?? true) {
                    issues.append("runtimeLifecycle tool.usageSummary requires non-empty toolNames")
                }
            }
        case .checkpoint:
            guard decode(payload.jsonUTF8, as: ConversationCheckpointTopicEventWire.self) != nil else {
                issues.append("checkpoint requires ConversationCheckpointTopicEventWire jsonUTF8")
                return issues
            }
        }
        return issues
    }

    static func validateConversationStatePayload(_ payload: ConversationStatePayload) -> [String] {
        var issues: [String] = []
        if payload.schemaVersion != ConversationStatePayload.schemaVersionV2 {
            issues.append("conversation state schemaVersion must be \(ConversationStatePayload.schemaVersionV2)")
        }
        if let catalog = payload.attachmentsCatalog {
            for item in catalog {
                if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("attachmentsCatalog entries require non-empty name")
                    break
                }
            }
        }
        return issues
    }

    static func validateConversationsRegistryPayload(_ payload: ConversationsRegistryPayload) -> [String] {
        var issues: [String] = []
        if payload.schemaVersion != ConversationsRegistryPayload.schemaVersionV1 {
            return ["conversations registry schemaVersion must be \(ConversationsRegistryPayload.schemaVersionV1)"]
        }
        for change in payload.changes {
            if let meta = change.metadata {
                let trimmedID = meta.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedID.isEmpty {
                    issues.append("conversations registry metadata.id must be non-empty")
                } else if UUID(uuidString: trimmedID) == nil {
                    issues.append("conversations registry metadata.id must be a UUID string")
                } else if trimmedID.lowercased() != change.conversationID.uuidString.lowercased() {
                    issues.append("conversations registry metadata.id must match change.conversationID")
                }
                if meta.messageCount < 0 {
                    issues.append("conversations registry metadata.messageCount must be >= 0")
                }
            }
        }
        return issues
    }

    static func validateToolsRegistryPayload(_ payload: ToolsRegistryPayload) -> [String] {
        if payload.schemaVersion != ToolsRegistryPayload.schemaVersionV1 {
            return ["tools registry schemaVersion must be \(ToolsRegistryPayload.schemaVersionV1)"]
        }
        return []
    }

    static func validateSkillsRegistryPayload(_ payload: SkillsRegistryPayload) -> [String] {
        if payload.schemaVersion != SkillsRegistryPayload.schemaVersionV1 {
            return ["skills registry schemaVersion must be \(SkillsRegistryPayload.schemaVersionV1)"]
        }
        return []
    }

    static func validateSubAgentsRegistryPayload(_ payload: SubAgentsRegistryPayload) -> [String] {
        if payload.schemaVersion != SubAgentsRegistryPayload.schemaVersionV2 {
            return ["sub-agents registry schemaVersion must be \(SubAgentsRegistryPayload.schemaVersionV2)"]
        }
        for entry in payload.entries {
            if entry.delegateToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ["sub-agents registry entries delegateToolName must be non-empty"]
            }
        }
        return []
    }

    static func validateSubAgentLifecycleTopicPayload(_ payload: SubAgentLifecycleTopicPayload) -> [String] {
        var issues: [String] = []
        if payload.schemaVersion != SubAgentLifecycleTopicPayload.schemaVersionV1 {
            issues.append("sub-agent lifecycle schemaVersion must be \(SubAgentLifecycleTopicPayload.schemaVersionV1)")
        }
        if payload.entries.contains(where: { $0.lifecycleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append("sub-agent lifecycle entries require non-empty lifecycleID")
        }
        if payload.entries.contains(where: { $0.parentConversationID != payload.parentConversationID }) {
            issues.append("sub-agent lifecycle entries parentConversationID must match payload parentConversationID")
        }
        if payload.entries.contains(where: { $0.eventTrustLevel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true }) {
            issues.append("sub-agent lifecycle entries eventTrustLevel must be non-empty when present")
        }
        if payload.entries.contains(where: { ($0.completionUsage?.promptTokens ?? 0) < 0 }) {
            issues.append("sub-agent lifecycle completionUsage.promptTokens must be >= 0")
        }
        if payload.entries.contains(where: { ($0.completionUsage?.completionTokens ?? 0) < 0 }) {
            issues.append("sub-agent lifecycle completionUsage.completionTokens must be >= 0")
        }
        if payload.entries.contains(where: { ($0.completionUsage?.totalTokens ?? 0) < 0 }) {
            issues.append("sub-agent lifecycle completionUsage.totalTokens must be >= 0")
        }
        if payload.entries.contains(where: { ($0.completionUsage?.costUSD ?? 0) < 0 }) {
            issues.append("sub-agent lifecycle completionUsage.costUSD must be >= 0")
        }
        return issues
    }

    static func validateTraceTopicPayload(_ payload: TraceTopicPayload) -> [String] {
        var issues: [String] = []
        if payload.schemaVersion != TraceTopicPayload.schemaVersionV1 {
            issues.append("trace payload schemaVersion must be \(TraceTopicPayload.schemaVersionV1)")
        }
        for span in payload.spans {
            if span.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("trace spans require non-empty name")
                break
            }
            if span.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("trace spans require non-empty category")
                break
            }
            if span.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("trace spans require non-empty source")
                break
            }
        }
        return issues
    }

    private static func jsonInteger(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double, let i = Int(exactly: d) { return i }
        return nil
    }

    private static func decode<T: Decodable>(_ jsonUTF8: String?, as type: T.Type) -> T? {
        guard let jsonUTF8,
              let data = jsonUTF8.data(using: .utf8)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private static func isValidJSON(_ jsonUTF8: String?) -> Bool {
        guard let jsonUTF8,
              let data = jsonUTF8.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
