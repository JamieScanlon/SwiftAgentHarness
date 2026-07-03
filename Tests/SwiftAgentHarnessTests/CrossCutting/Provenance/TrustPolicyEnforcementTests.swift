import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Trust policy enforcement")
struct TrustPolicyEnforcementTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    @Test("gateExecution mode forces tools/agents off for low-trust input")
    func gateExecutionDisablesRuntimeFlags() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            trustPolicyConfiguration: TrustPolicyConfiguration(mode: .gateExecution, safeDefaultClass: .lowTrust)
        )
        let applied = await runtimeSession.configurationApplyingTrustPolicy(
            .init(
                enableTools: true,
                enableAgents: true,
                inputTrustRaw: MessageInputTrust.automation.rawValue
            )
        )
        #expect(applied.enableTools == false)
        #expect(applied.enableAgents == false)
        #expect(applied.resolvedInputTrustClass == .lowTrust)
    }

    @Test("downgradeContext mode drops older low-trust user turns but keeps latest input")
    func downgradeContextDropsOlderLowTrustUserMessages() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(
            container: container,
            trustPolicyConfiguration: TrustPolicyConfiguration(mode: .downgradeContext, safeDefaultClass: .lowTrust)
        )
        let firstLowTrustUser = Message(
            id: UUID(),
            role: .user,
            content: "automated old",
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: MessageInputTrust.scripted.rawValue
        )
        let assistant = Message(id: UUID(), role: .assistant, content: "ack", timestamp: Date(), toolCalls: [])
        let latestLowTrustUser = Message(
            id: UUID(),
            role: .user,
            content: "latest",
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: MessageInputTrust.automation.rawValue
        )
        let adjusted = await runtimeSession.contextMessagesApplyingTrustPolicy(
            [firstLowTrustUser, assistant, latestLowTrustUser],
            configuration: .init(
                enableTools: true,
                enableAgents: true,
                inputTrustRaw: MessageInputTrust.scripted.rawValue
            )
        )
        #expect(adjusted.contains(where: { $0.id == assistant.id }))
        #expect(adjusted.contains(where: { $0.id == latestLowTrustUser.id }))
        #expect(!adjusted.contains(where: { $0.id == firstLowTrustUser.id }))
    }

    @Test("attachment catalog merge persists normalized attachment trust")
    func attachmentCatalogMergePersistsTrust() async throws {
        let (stack, _, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "trust-attachments")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversation = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let resource = CachedResource(id: UUID(), name: "img.png", fileType: "image")
        try stack.conversationManager.mergeAttachmentsCatalog(
            conversationID: conversation.id,
            resources: [resource],
            attachmentTrustRaw: "  \(AttachmentInputTrust.automation.rawValue) "
        )
        let reloaded = try #require(stack.conversationManager.modelConversation(id: conversation.id))
        #expect(reloaded.attachmentsCatalog.count == 1)
        #expect(reloaded.attachmentsCatalog[0].trustRaw == AttachmentInputTrust.automation.rawValue)
        #expect(reloaded.attachmentsCatalog[0].typedTrust == .automation)
        let record = try #require(try stack.conversationManager.sessionBackend.catalogConversation(id: conversation.id))
        let catalog = SessionCatalogResourceCodec.decode(record.resourceJSON)
        #expect(catalog?.attachmentsCatalog?.count == 1)
        #expect(catalog?.attachmentsCatalog?.first?.trustRaw == AttachmentInputTrust.automation.rawValue)
    }

    @Test("trust policy overrides apply only for known values")
    func trustPolicyOverrides() {
        let base = TrustPolicyConfiguration(mode: .none, safeDefaultClass: .lowTrust)
        let applied = base.applyingOverrides(
            modeRawOverride: TrustPolicyMode.gateAndDowngrade.rawValue,
            safeDefaultClassRawOverride: TrustPolicyClass.trusted.rawValue
        )
        #expect(applied.mode == .gateAndDowngrade)
        #expect(applied.safeDefaultClass == .trusted)

        let ignored = base.applyingOverrides(
            modeRawOverride: "unknown_mode",
            safeDefaultClassRawOverride: "future_class"
        )
        #expect(ignored.mode == .none)
        #expect(ignored.safeDefaultClass == .lowTrust)
    }

    @Test("attachment projection helper is trust and capability aware")
    func attachmentProjectionDecisionMatrix() {
        let trustedImage = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "image",
            name: "snapshot.png",
            mimeType: "image/png",
            byteSize: 10_000,
            trustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let lowTrustDoc = ConversationAttachmentDescriptor(
            id: UUID(),
            kind: "document",
            name: "scripted.txt",
            mimeType: "text/plain",
            byteSize: 99_999_999,
            trustRaw: AttachmentInputTrust.scripted.rawValue
        )
        let artifact = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjection(
            catalog: [trustedImage, lowTrustDoc],
            modelSupportsVision: false,
            policy: ContextEngineAttachmentProjectionPolicyInput(
                enabled: true,
                inlineByteLimit: 20_000,
                summarizeByteLimit: 500_000
            )
        )
        #expect(artifact != nil)
        let trustedDecision = artifact?.decisions.first(where: { $0.attachmentName == "snapshot.png" })
        let lowTrustDecision = artifact?.decisions.first(where: { $0.attachmentName == "scripted.txt" })
        #expect(trustedDecision?.disposition == .summarize)
        #expect(trustedDecision?.reason == "vision_unsupported")
        #expect(lowTrustDecision?.disposition == .searchOnly)
        #expect(lowTrustDecision?.reason == "low_trust")
    }
}
