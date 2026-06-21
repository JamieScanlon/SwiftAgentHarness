import Foundation
import SwiftAgentHarness
import Testing

@Suite("Message input trust codec")
struct MessageInputTrustTests {
    @Test("sanitizedInputTrustRaw trims and drops empty")
    func sanitizes() {
        #expect(MessageInputTrustCodec.sanitizedInputTrustRaw(nil) == nil)
        #expect(MessageInputTrustCodec.sanitizedInputTrustRaw("  ") == nil)
        #expect(MessageInputTrustCodec.sanitizedInputTrustRaw("  hello  ") == "hello")
    }

    @Test("MessageInputTrust raw values match SwiftAgentKit vocabulary examples")
    func knownCases() {
        #expect(MessageInputTrust.directUserEntry.rawValue == "direct_user_entry")
        #expect(MessageInputTrust.automation.rawValue == "automation")
        #expect(MessageInputTrust.scripted.rawValue == "scripted")
    }

    @Test("safePolicyClass keeps omitted trust trusted and unknown values on safe fallback")
    func safePolicyClassMapping() {
        #expect(MessageInputTrustCodec.safePolicyClass(raw: nil) == .trusted)
        #expect(MessageInputTrustCodec.safePolicyClass(raw: MessageInputTrust.directUserEntry.rawValue) == .trusted)
        #expect(MessageInputTrustCodec.safePolicyClass(raw: MessageInputTrust.automation.rawValue) == .lowTrust)
        #expect(MessageInputTrustCodec.safePolicyClass(raw: "future_value") == .lowTrust)
        #expect(MessageInputTrustCodec.safePolicyClass(raw: "future_value", unknownFallback: .trusted) == .trusted)
    }

    @Test("attachment trust typed helper and safe mapping are forward-compatible")
    func attachmentTrustMapping() {
        #expect(AttachmentInputTrustCodec.typedTrust(from: AttachmentInputTrust.directUserEntry.rawValue) == .directUserEntry)
        #expect(AttachmentInputTrustCodec.typedTrust(from: "unknown_value") == nil)
        #expect(AttachmentInputTrustCodec.safePolicyClass(raw: nil) == .trusted)
        #expect(AttachmentInputTrustCodec.safePolicyClass(raw: AttachmentInputTrust.scripted.rawValue) == .lowTrust)
    }

    @Test("attachment descriptor normalizes trustRaw and preserves known typed trust")
    func attachmentDescriptorTrustNormalization() {
        let descriptor = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "image",
            name: "a.png",
            trustRaw: "  \(AttachmentInputTrust.automation.rawValue) "
        )
        #expect(descriptor.trustRaw == AttachmentInputTrust.automation.rawValue)
        #expect(descriptor.typedTrust == .automation)
    }
}
