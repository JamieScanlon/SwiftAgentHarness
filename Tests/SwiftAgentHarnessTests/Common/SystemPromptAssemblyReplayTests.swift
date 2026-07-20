import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("SystemPromptAssemblyReplay")
struct SystemPromptAssemblyReplayTests {

    private func neutralProfile() -> ResolvedModeProfile {
        ResolvedModeProfile(
            id: InteractionMode.chat.rawValue,
            interactionMode: .chat,
            assemblyKind: .chat,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: false,
            builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
            semanticLayerTags: []
        )
    }

    private func neutralPolicy() -> ContextEngineSystemPromptAssemblyPolicyInput {
        ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: neutralProfile(),
            strictAgentHarnessPrompts: false,
            includeAgentSkills: false,
            includeDateTime: true,
            toolPolicySignature: "sig",
            routingPolicyTools: [],
            routingPolicySkills: []
        )
    }

    private func sampleConversation(systemPrompt: String = "Canonical system") -> ModelConversation {
        ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: systemPrompt
        )
    }

    @Test("Replay spec digest changes when user system prompt changes")
    func replaySpecDigestTracksUserSystemPrompt() async throws {
        let conv = sampleConversation()
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let iso = SystemPrompt.assembleReferenceDateISOString(from: frozen)
        let bundleA = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Alpha",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            referenceDate: frozen
        )
        let bundleB = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Beta",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            referenceDate: frozen
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let auditA = try await renderer.renderWithAudit(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Alpha",
            assemblyContext: bundleA.assemblyContext,
            contributions: bundleA.contributions,
            referenceDate: frozen,
            fullOverrideText: bundleA.fullOverrideText
        )
        let auditB = try await renderer.renderWithAudit(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Beta",
            assemblyContext: bundleB.assemblyContext,
            contributions: bundleB.contributions,
            referenceDate: frozen,
            fullOverrideText: bundleB.fullOverrideText
        )
        let specA = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp-a",
            assembleReferenceDateISO: iso,
            audit: auditA,
            contributions: bundleA.contributions
        )
        let specB = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp-a",
            assembleReferenceDateISO: iso,
            audit: auditB,
            contributions: bundleB.contributions
        )
        #expect(specA.replaySpecDigest != specB.replaySpecDigest)
    }

    @Test("Replay spec digest changes when reference date changes")
    func replaySpecDigestTracksReferenceDate() async throws {
        let conv = sampleConversation()
        let dateA = Date(timeIntervalSince1970: 1_700_000_000)
        let dateB = Date(timeIntervalSince1970: 1_800_000_000)
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Same",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            referenceDate: dateA
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let auditA = try await renderer.renderWithAudit(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Same",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: dateA,
            fullOverrideText: bundle.fullOverrideText
        )
        let auditB = try await renderer.renderWithAudit(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Same",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: dateB,
            fullOverrideText: bundle.fullOverrideText
        )
        let specA = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: SystemPrompt.assembleReferenceDateISOString(from: dateA),
            audit: auditA,
            contributions: bundle.contributions
        )
        let specB = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: SystemPrompt.assembleReferenceDateISOString(from: dateB),
            audit: auditB,
            contributions: bundle.contributions
        )
        #expect(specA.replaySpecDigest != specB.replaySpecDigest)
    }

    @Test("Reassemble equals live render digest")
    func reassembleMatchesLiveRender() async throws {
        let conv = sampleConversation()
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = [Message(id: UUID(), role: .system, content: "Canonical system", timestamp: frozen, toolCalls: [])]
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Canonical system",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            referenceDate: frozen
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let audit = try await renderer.renderWithAudit(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Canonical system",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: frozen,
            fullOverrideText: bundle.fullOverrideText
        )
        let fingerprint = SystemPromptAssemblyFingerprint.hexDigest(
            resolved: neutralProfile(),
            strictAgentHarnessPrompts: false,
            includeAgentSkills: false,
            includeDateTime: true,
            toolPolicySignature: "sig",
            routingPolicyTools: [],
            routingPolicySkills: [],
            memorySnapshotGeneration: nil,
            workspaceSectionContent: bundle.memorySlice.workspaceContent,
            memoryTier1SectionContent: bundle.memorySlice.tier1Content,
            providerContributionSignature: bundle.providerContributionSignature,
            systemPromptFullOverride: false
        )
        let replaySpec = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: fingerprint,
            assembleReferenceDateISO: SystemPrompt.assembleReferenceDateISOString(from: frozen),
            audit: audit,
            contributions: bundle.contributions
        )
        let replayed = try await SystemPromptAssemblyReplayer.reassemble(
            conversation: conv,
            messagesAtFrontier: messages,
            policy: neutralPolicy(),
            replaySpec: replaySpec,
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            frozenSkillsIndexXML: audit.product.frozenSkillsIndexXML,
            skillLoader: nil,
            logger: nil
        )
        #expect(SystemPromptDispatchCodec.sha256Digest(of: replayed) == SystemPromptDispatchCodec.sha256Digest(of: audit.text))
    }

    @Test("Frozen skills index survives index drift during replay")
    func frozenSkillsIndexSurvivesDiskDrift() async throws {
        let conv = sampleConversation()
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let originalIndex = "<skills><skill name=\"audit-skill\" description=\"v1\"/></skills>"
        let mutatedIndex = "<skills><skill name=\"audit-skill\" description=\"v2\"/></skills>"
        let policy = ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: neutralProfile(),
            strictAgentHarnessPrompts: false,
            includeAgentSkills: true,
            includeDateTime: false,
            toolPolicySignature: "sig",
            routingPolicyTools: [],
            routingPolicySkills: []
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: policy,
            userSystemPrompt: nil,
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            referenceDate: frozen
        )
        var context = bundle.assemblyContext
        context.frozenSkillsIndexXML = originalIndex
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let audit = try await renderer.renderWithAudit(
            conversation: conv,
            policy: policy,
            userSystemPrompt: nil,
            assemblyContext: context,
            contributions: bundle.contributions,
            referenceDate: frozen,
            fullOverrideText: bundle.fullOverrideText
        )
        let replaySpec = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: SystemPrompt.assembleReferenceDateISOString(from: frozen),
            audit: audit,
            contributions: bundle.contributions
        )
        let replayedOriginal = try await SystemPromptAssemblyReplayer.reassemble(
            conversation: conv,
            messagesAtFrontier: [],
            policy: policy,
            replaySpec: replaySpec,
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            frozenSkillsIndexXML: originalIndex,
            skillLoader: nil,
            logger: nil
        )
        let replayedMutated = try await SystemPromptAssemblyReplayer.reassemble(
            conversation: conv,
            messagesAtFrontier: [],
            policy: policy,
            replaySpec: replaySpec,
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            frozenSkillsIndexXML: mutatedIndex,
            skillLoader: nil,
            logger: nil
        )
        #expect(audit.text.contains("description=\"v1\""))
        #expect(replayedOriginal.contains("description=\"v1\""))
        #expect(replayedMutated.contains("description=\"v2\""))
        #expect(replayedMutated != replayedOriginal)
    }

    @Test("Major sections emit provenance tags; Constraints has no contributor tag")
    func provenanceTagsOnSections() async throws {
        let conv = sampleConversation()
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Canonical system",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on"
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let audit = try await renderer.renderWithAudit(
            conversation: conv,
            policy: neutralPolicy(),
            userSystemPrompt: "Canonical system",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: Date(),
            fullOverrideText: bundle.fullOverrideText
        )
        #expect(audit.text.contains("<!-- provenance:"))
        #expect(audit.text.contains("# Constraints"))
        let constraintsRange = try #require(audit.text.range(of: "# Constraints"))
        let constraintsPrefix = String(audit.text[..<constraintsRange.lowerBound].suffix(80))
        #expect(constraintsPrefix.contains("<!-- provenance:") == false)
        #expect(!audit.product.sectionProvenance.isEmpty)
    }

    @Test("v3 digestOnly wire validates with replaySpecDigest")
    func v3DigestOnlyValidity() {
        let wire = SystemPromptAssemblyCheckpointWire(
            schemaVersion: 3,
            basedOnEventID: 1,
            assemblyFingerprint: "fp",
            assembledPromptDigest: "digest",
            replaySpecDigest: "replay-digest",
            assembledPrompt: nil,
            sectionProvenanceJSON: nil,
            createdAt: Date()
        )
        let events = [
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 1,
                kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(wire),
                createdAt: Date()
            ),
        ]
        let selected = SuiteCheckpointSupport.latestValidSystemPromptAssembly(events: events, frontierEventID: 1)
        #expect(selected?.wire.replaySpecDigest == "replay-digest")
        #expect(selected?.wire.assembledPrompt == nil)
    }

    @Test("v3 fullText wire validates digest match")
    func v3FullTextValidity() {
        let text = "assembled prompt body"
        let digest = SystemPromptDispatchCodec.sha256Digest(of: text)
        let wire = SystemPromptAssemblyCheckpointWire(
            schemaVersion: 3,
            basedOnEventID: 1,
            assemblyFingerprint: "fp",
            assembledPromptDigest: digest,
            replaySpecDigest: "replay-digest",
            assembledPrompt: text,
            sectionProvenanceJSON: "{\"tools\":\"defaults\"}",
            createdAt: Date()
        )
        let events = [
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 1,
                kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(wire),
                createdAt: Date()
            ),
        ]
        let selected = SuiteCheckpointSupport.latestValidSystemPromptAssembly(events: events, frontierEventID: 1)
        #expect(selected?.wire.assembledPrompt == text)
    }

    @Test("v2 checkpoints remain valid without replay spec digest")
    func v2BackwardCompatibility() {
        let wire = SystemPromptAssemblyCheckpointWire(
            schemaVersion: 2,
            basedOnEventID: 1,
            assemblyFingerprint: "fp",
            assembledPromptDigest: "digest",
            createdAt: Date()
        )
        let events = [
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 1,
                kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
                payloadJSON: ConversationEventCodec.encode(wire),
                createdAt: Date()
            ),
        ]
        #expect(SuiteCheckpointSupport.latestValidSystemPromptAssembly(events: events, frontierEventID: 1) != nil)
    }

    @Test("Replay spec captures prompt config snapshot; ambient mutation does not change digest")
    func replaySpecCapturesPromptConfigSnapshot() async throws {
        defer { PromptConfigBundleResource.resetForTesting() }
        let captureJSON = """
        {
          "options": {
            "includeAgentSkills": false,
            "includeCurrentDateTime": false,
            "systemPromptAssemblyCheckpoint": { "mode": "fullText", "maxFullTextBytes": 4096 }
          },
          "agentHarness": { "strictAgentHarnessPrompts": false }
        }
        """
        let captureData = Data(captureJSON.utf8)

        let conv = sampleConversation()
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: neutralProfile(),
            strictAgentHarnessPrompts: false,
            includeAgentSkills: false,
            includeDateTime: false,
            toolPolicySignature: "sig",
            routingPolicyTools: [],
            routingPolicySkills: []
        )
        let bundle = SystemPromptAssemblyContributionCollector.collect(
            conversation: conv,
            policy: policy,
            userSystemPrompt: "Canonical system",
            memoryBlocks: nil,
            memorySnapshotGeneration: nil,
            modeMemoryInjection: "on",
            referenceDate: frozen
        )
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let audit = try await renderer.renderWithAudit(
            conversation: conv,
            policy: policy,
            userSystemPrompt: "Canonical system",
            assemblyContext: bundle.assemblyContext,
            contributions: bundle.contributions,
            referenceDate: frozen,
            fullOverrideText: bundle.fullOverrideText
        )
        let snapshot = HarnessConfigurationSet.load(
            from: try PromptConfigDocument.parse(data: captureData)
        ).promptAssemblyConfigSnapshot
        let spec = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: SystemPrompt.assembleReferenceDateISOString(from: frozen),
            audit: audit,
            contributions: bundle.contributions,
            policy: policy,
            promptConfigSnapshot: snapshot
        )
        #expect(spec.promptConfigSnapshot.includeAgentSkills == false)
        #expect(spec.promptConfigSnapshot.assemblyCheckpointMode == .fullText)
        #expect(spec.promptConfigSnapshot.assemblyCheckpointMaxFullTextBytes == 4096)
        let digestBefore = spec.replaySpecDigest

        let mutateJSON = """
        {
          "options": {
            "includeAgentSkills": true,
            "includeCurrentDateTime": true,
            "systemPromptAssemblyCheckpoint": { "mode": "off" }
          },
          "agentHarness": { "strictAgentHarnessPrompts": true }
        }
        """
        PromptConfigBundleResource.configure(data: Data(mutateJSON.utf8))
        #expect(spec.replaySpecDigest == digestBefore)
        #expect(spec.promptConfigSnapshot.includeAgentSkills == false)
        #expect(SystemPromptAssemblyCheckpointConfiguration.load(from: spec.promptConfigSnapshot).mode == .fullText)
    }
}
