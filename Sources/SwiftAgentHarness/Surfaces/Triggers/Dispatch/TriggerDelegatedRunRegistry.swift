import Foundation

struct TriggerDelegatedRunRecord: Sendable, Equatable {
    var trigger: HarnessTrigger
    var parentConversationID: UUID
    var childConversationID: UUID
    var sessionKey: String
}

actor TriggerDelegatedRunRegistry {
    private var byChildID: [UUID: TriggerDelegatedRunRecord] = [:]
    private var deliveredKeys: Set<String> = []

    func register(_ record: TriggerDelegatedRunRecord) {
        byChildID[record.childConversationID] = record
    }

    func record(forChildConversationID childID: UUID) -> TriggerDelegatedRunRecord? {
        byChildID[childID]
    }

    func record(forParentConversationID parentID: UUID, childID: UUID) -> TriggerDelegatedRunRecord? {
        guard let record = byChildID[childID], record.parentConversationID == parentID else {
            return nil
        }
        return record
    }

    func markDelivered(triggerID: String, childSessionID: UUID, announceID: String?) -> Bool {
        let key = deliveryKey(triggerID: triggerID, childSessionID: childSessionID, announceID: announceID)
        if deliveredKeys.contains(key) {
            return false
        }
        deliveredKeys.insert(key)
        return true
    }

    func reset() {
        byChildID.removeAll()
        deliveredKeys.removeAll()
    }

    private func deliveryKey(triggerID: String, childSessionID: UUID, announceID: String?) -> String {
        "\(triggerID):\(childSessionID.uuidString):\(announceID ?? "none")"
    }
}
