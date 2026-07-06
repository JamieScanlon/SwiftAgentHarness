import Testing
@testable import SwiftAgentHarness

struct CommEnvelopeTrustTagTests {
    @Test func messageInputTrustMapping() {
        let omitted = CommEnvelopeTrustTag.fromMessageInputTrustRaw(nil)
        #expect(omitted.trustClass == .restricted)
        #expect(omitted.originTrust == .unknownParty)

        let direct = CommEnvelopeTrustTag.fromMessageInputTrustRaw("direct_user_entry")
        #expect(direct.trustClass == .trusted)
        #expect(direct.originTrust == .userDirect)

        let scripted = CommEnvelopeTrustTag.fromMessageInputTrustRaw("scripted")
        #expect(scripted.trustClass == .restricted)
        #expect(scripted.originTrust == .userDeferred)

        let unknown = CommEnvelopeTrustTag.fromMessageInputTrustRaw("custom_sender")
        #expect(unknown.trustClass == .restricted)
        #expect(unknown.originTrust == .unknownParty)
    }

    @Test func subAgentTrustMapping() {
        let known = CommEnvelopeTrustTag.fromSubAgentTrustRaw("known-party")
        #expect(known.trustClass == .trusted)
        #expect(known.originTrust == .knownParty)

        let unknown = CommEnvelopeTrustTag.fromSubAgentTrustRaw("unknown-party")
        #expect(unknown.trustClass == .restricted)
        #expect(unknown.originTrust == .unknownParty)
    }

    @Test func floorChoosesMostRestrictiveClassAndOrigin() {
        let tags: [CommEnvelopeTrustTag] = [
            CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .system),
            CommEnvelopeTrustTag(trustClass: .trusted, originTrust: .knownParty),
            CommEnvelopeTrustTag(trustClass: .restricted, originTrust: .userDeferred),
        ]
        let result = CommEnvelopeTrustTag.mostRestrictive(tags)
        #expect(result.trustClass == .restricted)
        #expect(result.originTrust == .userDeferred)
    }
}
