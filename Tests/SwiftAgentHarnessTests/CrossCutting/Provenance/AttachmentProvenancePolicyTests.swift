import Foundation
import SwiftAgentHarness
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment provenance policy")
struct AttachmentProvenancePolicyTests {
    private func descriptor(trustRaw: String?, addedBy: ConversationAttachmentAddedBy? = nil) -> ConversationAttachmentDescriptor {
        ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "document",
            name: "sample.txt",
            addedBy: addedBy,
            trustRaw: trustRaw
        )
    }

    @Test("user-direct attachments do not require external envelope")
    func userDirectNoEnvelope() {
        let descriptor = descriptor(trustRaw: CommEnvelopeOriginTrust.userDirect.rawValue)
        #expect(!AttachmentProvenancePolicy.requiresExternalEnvelope(trustRaw: descriptor.trustRaw))
        #expect(!AttachmentProvenancePolicy.includeSecurityPreamble(trustRaw: descriptor.trustRaw))
        let wrapped = AttachmentProvenancePolicy.wrapIfRequired(descriptor: descriptor, content: "plain body")
        #expect(wrapped == "plain body")
        #expect(!ExternalContentEnvelope.isAlreadyWrapped(wrapped))
    }

    @Test("unknown-party attachments require envelope with security preamble")
    func unknownPartyEnvelope() {
        let descriptor = descriptor(trustRaw: CommEnvelopeOriginTrust.unknownParty.rawValue)
        #expect(AttachmentProvenancePolicy.requiresExternalEnvelope(trustRaw: descriptor.trustRaw))
        #expect(AttachmentProvenancePolicy.includeSecurityPreamble(trustRaw: descriptor.trustRaw))
        let wrapped = AttachmentProvenancePolicy.wrapIfRequired(descriptor: descriptor, content: "hostile body")
        #expect(ExternalContentEnvelope.isAlreadyWrapped(wrapped))
        #expect(wrapped.contains("SECURITY NOTICE"))
    }

    @Test("known-party attachments require envelope with default preamble")
    func knownPartyEnvelope() {
        let descriptor = descriptor(trustRaw: CommEnvelopeOriginTrust.knownParty.rawValue)
        #expect(AttachmentProvenancePolicy.requiresExternalEnvelope(trustRaw: descriptor.trustRaw))
        #expect(AttachmentProvenancePolicy.includeSecurityPreamble(trustRaw: descriptor.trustRaw))
        let wrapped = AttachmentProvenancePolicy.wrapIfRequired(descriptor: descriptor, content: "webhook body")
        #expect(ExternalContentEnvelope.isAlreadyWrapped(wrapped))
    }

    @Test("legacy automation and scripted trust map to envelope-required origins")
    func legacyLowTrustEnvelope() {
        for trust in [AttachmentInputTrust.automation.rawValue, AttachmentInputTrust.scripted.rawValue] {
            let descriptor = descriptor(trustRaw: trust)
            #expect(AttachmentProvenancePolicy.requiresExternalEnvelope(trustRaw: trust))
            #expect(ExternalContentEnvelope.isAlreadyWrapped(
                AttachmentProvenancePolicy.wrapIfRequired(descriptor: descriptor, content: "x")
            ))
        }
    }

    @Test("agent-fetched attachments use web_fetch source label")
    func agentFetchedSourceLabel() {
        let descriptor = descriptor(
            trustRaw: CommEnvelopeOriginTrust.unknownParty.rawValue,
            addedBy: .agent
        )
        #expect(AttachmentProvenancePolicy.externalContentSource(descriptor: descriptor) == .webFetch)
    }

    @Test("default trust raw follows addedBy")
    func defaultTrustRawByAddedBy() {
        #expect(
            AttachmentProvenancePolicy.defaultTrustRaw(for: .user)
                == CommEnvelopeOriginTrust.userDirect.rawValue
        )
        #expect(
            AttachmentProvenancePolicy.defaultTrustRaw(for: .agent)
                == CommEnvelopeOriginTrust.unknownParty.rawValue
        )
    }
}
