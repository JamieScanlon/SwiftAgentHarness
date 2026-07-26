import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Live-path regression: ingest refs → session-tree wipe → CE restore → LM Studio `image_url`.
@Suite("Vision image assemble-to-wire regression")
struct VisionImageAssembleToWireRegressionTests {
    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    @Test("nil catalog byteSize with loadable blob stays inline (not unknown_size)")
    func nilByteSizeResolvesFromBlobToInline() throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let blobRef = try harness.putBlob(
            data: tinyPNG,
            durability: .durable,
            originalName: "shot.png",
            mimeType: "image/png",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        let attachment = ConversationAttachmentDescriptor(
            id: UUID(),
            blobId: blobRef.id,
            kind: "image",
            name: "shot.png",
            mimeType: "image/png",
            byteSize: nil
        )
        let artifact = ContextEngineAttachmentProjectionPolicyHelper.resolveAttachmentProjectionArtifact(
            catalog: [attachment],
            modelSupportsVision: true,
            policy: ContextEngineAttachmentProjectionPolicyInput(),
            blobReader: AttachmentBlobReading.harness(harness, conversationID: conversationID),
            conversationID: conversationID,
            messages: []
        )
        let decision = try #require(artifact?.decisions.first)
        #expect(decision.disposition == .inline)
        #expect(decision.reason != "unknown_size")
        #expect(
            decision.reason == "within_image_inline_budget"
                || decision.reason == "sanitize_to_inline_budget"
        )
    }

    @Test("session-tree replay + vision project keeps imageData and LMStudio image_url")
    func sessionTreeAssembleEncodesImageURL() async throws {
        let harness = InMemoryHarnessSessionPersistence()
        let conversationID = UUID()
        let blobRef = try harness.putBlob(
            data: tinyPNG,
            durability: .durable,
            originalName: "gym.jpg",
            mimeType: "image/jpeg",
            trust: AttachmentInputTrust.directUserEntry.rawValue,
            ttlSeconds: nil,
            lane: .inbound
        )
        let attachmentID = UUID()
        // Catalog size intentionally nil — must resolve from blob, not demote to unknown_size.
        let attachment = ConversationAttachmentDescriptor(
            id: attachmentID,
            blobId: blobRef.id,
            kind: "image",
            name: "gym.jpg",
            mimeType: "image/jpeg",
            byteSize: nil
        )
        let userMessage = Message(
            id: UUID(),
            role: .user,
            content: "can you tell me the manufacturer of this gym equipment?",
            timestamp: Date(),
            images: [Message.Image(name: attachment.name, path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: [],
            inputTrustRaw: AttachmentInputTrust.directUserEntry.rawValue
        )
        let systemMessage = Message(
            id: UUID(),
            role: .system,
            content: "You are a helpful agent.",
            timestamp: Date(),
            toolCalls: []
        )
        let ingestRef = AttachmentIngestRef(
            attachmentId: attachmentID,
            blobId: blobRef.id,
            name: attachment.name,
            kind: "image",
            mimeType: "image/jpeg",
            trust: AttachmentInputTrust.directUserEntry.rawValue
        )
        let transcriptEntries = [
            try SessionTranscriptMapping.entry(from: systemMessage, sequence: 0, parentEntryId: nil),
            try SessionTranscriptMapping.entry(
                from: userMessage,
                sequence: 1,
                parentEntryId: nil,
                attachmentIngestRefs: [ingestRef]
            ),
        ]
        let blobReader = AttachmentBlobReading.harness(harness, conversationID: conversationID)
        // Conversation model omits .vision; policy forces vision true (registry-aligned path).
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "qwen/qwen3.6-27b",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        var conversation = ModelConversation(
            id: conversationID,
            model: model,
            messages: [systemMessage, userMessage],
            systemPrompt: "You are a helpful agent."
        )
        conversation.attachmentsCatalog = [attachment]

        let policy = ContextEngineProjectionPolicyInput(
            attachmentCatalog: [attachment],
            modelSupportsVision: true,
            attachmentProjectionPolicy: ContextEngineAttachmentProjectionPolicyInput(),
            attachmentBlobReader: blobReader,
            useSessionTreeProjection: true,
            sessionTranscriptEntries: transcriptEntries
        )

        let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
        let assembleReq = ContextEngineAssembleRequest(
            messages: [systemMessage, userMessage],
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil,
            compactionCustomInstructionsOverride: nil,
            enableContextTransform: true,
            compactionConfig: .default,
            transformMetadata: ConversationTransformMetadata(
                conversationID: conversation.id,
                modelID: conversation.model.id.uuidString,
                modelName: conversation.model.modelName,
                interactionMode: conversation.interactionMode,
                routingPolicyTools: [],
                routingPolicySkills: [],
                thinkingEnabled: false,
                reasoningEffort: nil,
                metadata: nil
            ),
            lastContextLimitTokens: nil,
            lastPromptTokens: nil,
            events: [],
            eventLogFrontier: 0,
            lastModelRequestAtByConversationID: [:],
            lastCompactionLLMDateByConversationID: [:],
            persistCompactionCheckpoint: false,
            allowProactiveCompactionTriggers: true,
            compactionLockAlreadyHeldByCaller: false,
            derivedTailAtProjectionStart: 0,
            projectionPolicy: policy
        )
        let result = await engine.assemble(request: assembleReq) { input in
            ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
        }
        #expect(result.transformFailed == false)
        let assembledUser = try #require(result.messages.last { $0.role == .user })
        #expect(assembledUser.images.count == 1)
        let imageData = try #require(assembledUser.images[0].imageData)
        #expect(!imageData.isEmpty)

        let decisions = result.projectionArtifact?.attachmentProjection?.decisions ?? []
        let dispositionParams: JSON = .object([
            "contextEngineAttachmentProjection": .object([
                "projectionFingerprint": .string("test"),
                "decisions": .array(decisions.map { decision in
                    .object([
                        "attachmentName": .string(decision.attachmentName),
                        "disposition": .string(decision.disposition.rawValue),
                    ])
                }),
                "materializedBlocks": .array([]),
            ]),
        ])
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = LMStudioLLM(
            model: model.modelName,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .vision],
            systemPrompt: prompt
        )
        let body = try await llm.testEncodedChatRequestBody(
            from: result.messages,
            config: LLMRequestConfig(additionalParameters: dispositionParams)
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userWire = try #require(messages.last { ($0["role"] as? String) == "user" })
        guard let parts = userWire["content"] as? [[String: Any]] else {
            Issue.record("Expected multimodal content array, got \(String(describing: userWire["content"]))")
            return
        }
        #expect(parts.contains { ($0["type"] as? String) == "image_url" })
    }
}
