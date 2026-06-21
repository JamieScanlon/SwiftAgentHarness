//
//  Maps internal compaction payloads to wire DTOs for REST.
//

extension ContextCompactionCheckpointPayload {
    func toWireDTO() -> ContextCompactionCheckpointWire {
        ContextCompactionCheckpointWire(
            schemaVersion: schemaVersion,
            kind: kind.rawValue,
            coveredMessageIDs: coveredMessageIDs,
            syntheticMessages: syntheticMessages.map {
                ContextCompactionSyntheticMessageWire(id: $0.id, role: $0.role, content: $0.content)
            },
            configFingerprint: configFingerprint,
            basedOnEventID: basedOnEventID,
            basedOnTailMessageID: basedOnTailMessageID,
            strategyRawValue: strategyRawValue,
            cachePolicyFingerprint: cachePolicyFingerprint,
            createdAt: createdAt
        )
    }
}
