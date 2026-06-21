import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerPromptBuilder")
struct TriggerPromptBuilderTests {
    let builder = TriggerPromptBuilder()

    @Test("user-deferred includes provenance reminder")
    func userDeferredReminder() {
        let trigger = HarnessTrigger(
            id: "1",
            source: .cron,
            payload: "run digest",
            initiator: TriggerInitiator(kind: .user),
            trust: .userDeferred
        )
        let built = builder.build(trigger: trigger)
        #expect(built.systemReminder?.contains("[trigger-context]") == true)
        #expect(built.userMessageBody.contains("[trigger]"))
        #expect(built.userMessageBody.contains("run digest"))
    }

    @Test("unknown-party wraps payload")
    func unknownPartyEnvelope() {
        let trigger = HarnessTrigger(
            id: "2",
            source: .webhook,
            payload: "evil",
            initiator: TriggerInitiator(kind: .external),
            trust: .unknownParty
        )
        let built = builder.build(trigger: trigger)
        #expect(built.userMessageBody.contains("EXTERNAL_UNTRUSTED_CONTENT"))
        #expect(built.systemReminder != nil)
    }

    @Test("known-party wraps payload with security preamble")
    func knownPartyEnvelope() {
        let trigger = HarnessTrigger(
            id: "3",
            source: .webhook,
            payload: "authenticated payload",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        let built = builder.build(trigger: trigger)
        #expect(built.userMessageBody.contains("EXTERNAL_UNTRUSTED_CONTENT"))
        #expect(built.userMessageBody.contains("SECURITY NOTICE"))
    }

    @Test("known-party channel content includes security preamble by default")
    func knownPartyChannelPreamble() {
        let payload = """
        {"text":"hello from slack","attachments":[]}
        """
        let trigger = HarnessTrigger(
            id: "4",
            source: .channel,
            sourceMetadata: ["senderId": "U999"],
            payload: payload,
            payloadFormat: .structured,
            initiator: TriggerInitiator(kind: .external, id: "U999"),
            trust: .knownParty
        )
        let built = builder.build(trigger: trigger)
        #expect(built.userMessageBody.contains("hello from slack"))
        #expect(built.userMessageBody.contains("SECURITY NOTICE"))
        #expect(built.userMessageBody.contains("Channel metadata"))
    }

    @Test("known-party can omit security preamble when configured off")
    func knownPartyPreambleDisabled() {
        let trigger = HarnessTrigger(
            id: "5",
            source: .webhook,
            sourceMetadata: ["includeKnownPartySecurityPreamble": "false"],
            payload: "authenticated payload",
            initiator: TriggerInitiator(kind: .external),
            trust: .knownParty
        )
        let built = builder.build(trigger: trigger)
        #expect(built.userMessageBody.contains("EXTERNAL_UNTRUSTED_CONTENT"))
        #expect(!built.userMessageBody.contains("SECURITY NOTICE"))
    }

    @Test("unknown-party keeps security preamble even when known-party override is false")
    func unknownPartyPreambleAlwaysOn() {
        let trigger = HarnessTrigger(
            id: "6",
            source: .webhook,
            sourceMetadata: ["includeKnownPartySecurityPreamble": "false"],
            payload: "hostile payload",
            initiator: TriggerInitiator(kind: .external),
            trust: .unknownParty
        )
        let built = builder.build(trigger: trigger)
        #expect(built.userMessageBody.contains("SECURITY NOTICE"))
    }
}
