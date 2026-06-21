import Foundation

enum TriggerProvenanceReminder {
    static func build(trigger: HarnessTrigger) -> String {
        let iso = TriggerTimestampFormatting.isoString(
            from: Date(timeIntervalSince1970: TimeInterval(trigger.receivedAt) / 1000)
        )
        let initiator = trigger.initiator.id.map { "\(trigger.initiator.kind.rawValue):\($0)" } ?? trigger.initiator.kind.rawValue
        return """
        [trigger-context]
        This turn was initiated by \(trigger.source.rawValue) at \(iso) on behalf of \(initiator).
        Trust level: \(trigger.trust.rawValue).
        The user is not actively present — proceed without asking clarifying questions.
        If information is ambiguous, fail closed (refuse, log, or defer) rather than guessing.
        [/trigger-context]
        """
    }
}
