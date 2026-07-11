import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitSkills
@testable import SwiftAgentHarness

@Suite("SP6 Skills Index and Tool Result Bodies")
struct SP6SkillsIndexToolResultTests {

    private func makeSkillDirectory(named name: String, instructions: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp6-skills-\(UUID().uuidString)", isDirectory: true)
        let skillDir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(name)
        description: Test skill \(name)
        ---

        \(instructions)
        """
        try markdown.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    @Test("agent-skill-activate result includes name header and full instructions")
    func activateToolReturnsFormattedBody() async throws {
        let skillsRoot = try makeSkillDirectory(named: "demo-skill", instructions: "Do the demo steps.")
        let loader = SkillLoader(skillsDirectoryURL: skillsRoot, logger: nil)
        let provider = SkillPolicySkillsToolProvider(
            inner: SkillsToolProvider(loader: loader, logger: nil),
            canActivateSkill: { _ in true }
        )
        let call = ToolCall(
            name: SkillsToolProvider.activateToolName,
            arguments: .object(["skill_name": .string("demo-skill")]),
            id: "tc-1"
        )
        let result = try await provider.executeTool(call)
        #expect(result.success)
        #expect(result.content.hasPrefix("demo-skill:\n"))
        #expect(result.content.contains("Do the demo steps."))
    }

    @Test("Rendered prompt has skills index only without activated block")
    func promptOmitsActivatedSkillsBlock() async throws {
        let skillsRoot = try makeSkillDirectory(named: "index-only", instructions: "Hidden from prompt.")
        let loader = SkillLoader(skillsDirectoryURL: skillsRoot, logger: nil)
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: true,
            skillLoader: loader,
            skipConfigLoad: true
        )
        var context = SystemPromptAssemblyContext(
            conversationID: "conv",
            conversationStartDate: "2026-01-01"
        )
        context.frozenSkillsIndexXML = SkillPromptFormatter.formatAsXML(try await loader.loadMetadata())
        let product = try await prompt.renderAssemblyProduct(
            context: context,
            resolved: ResolvedSystemPromptSections(),
            stablePrefix: nil,
            providerID: nil,
            modeProfileID: nil
        )
        #expect(product.text.contains("Available Agent Skills:"))
        #expect(product.text.contains("activation tool result"))
        #expect(product.text.contains("Activated Agent Skills:") == false)
        #expect(product.text.contains("Hidden from prompt.") == false)
    }

    @Test("Activating a skill does not rewrite the stable skills index prefix")
    func promptStablePrefixUnchangedAfterActivation() async throws {
        let skillsRoot = try makeSkillDirectory(named: "stable-skill", instructions: "Stable body.")
        let loader = SkillLoader(skillsDirectoryURL: skillsRoot, logger: nil)
        let frozenIndex = SkillPromptFormatter.formatAsXML(try await loader.loadMetadata())
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: true,
            skillLoader: loader,
            skipConfigLoad: true
        )
        var context = SystemPromptAssemblyContext(
            conversationID: "conv",
            conversationStartDate: "2026-01-01",
            referenceDate: referenceDate,
            frozenSkillsIndexXML: frozenIndex
        )
        let resolved = ResolvedSystemPromptSections()
        let before = try await prompt.renderAssemblyProduct(
            context: context,
            resolved: resolved,
            stablePrefix: nil,
            providerID: nil,
            modeProfileID: nil
        )
        await loader.activateSkill(named: "stable-skill")
        let after = try await prompt.renderAssemblyProduct(
            context: context,
            resolved: resolved,
            stablePrefix: nil,
            providerID: nil,
            modeProfileID: nil
        )
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        let beforeStable = before.text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(while: { !$0.contains(marker) })
            .joined(separator: "\n")
        let afterStable = after.text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(while: { !$0.contains(marker) })
            .joined(separator: "\n")
        #expect(beforeStable == afterStable)
        #expect(before.text == after.text)
    }

    @Test("Replay spec digest changes when frozen index changes but not when only activation set changes")
    func replaySpecDigestTracksIndexNotActivation() async throws {
        let conv = ModelConversation(
            model: Model(
                protocol: .openAIAPI,
                modelName: "x",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            messages: [],
            systemPrompt: "sys"
        )
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = ContextEngineSystemPromptAssemblyPolicyInput(
            resolvedModeProfile: ResolvedModeProfile(
                id: InteractionMode.chat.rawValue,
                interactionMode: .chat,
                assemblyKind: .chat,
                allowsProactiveCompactionTriggers: true,
                appliesAgentBuildOrchestratorHarness: false,
                builtInSeedVersion: ResolvedModeProfile.builtInSeedVersion,
                semanticLayerTags: []
            ),
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
        var contextA = bundle.assemblyContext
        contextA.frozenSkillsIndexXML = "<skills><skill name=\"a\"/></skills>"
        var contextB = bundle.assemblyContext
        contextB.frozenSkillsIndexXML = "<skills><skill name=\"b\"/></skills>"
        let renderer = DefaultSystemPromptAssemblyRenderer(skillLoaderProvider: { _ in nil }, logger: nil)
        let auditA = try await renderer.renderWithAudit(
            conversation: conv,
            policy: policy,
            userSystemPrompt: nil,
            assemblyContext: contextA,
            contributions: bundle.contributions,
            referenceDate: frozen,
            fullOverrideText: bundle.fullOverrideText
        )
        var auditAActivated = auditA
        auditAActivated = SystemPromptAssemblyRenderAudit(
            text: auditA.text,
            product: SystemPromptAssemblyRenderProduct(
                text: auditA.text,
                sectionProvenance: auditA.product.sectionProvenance,
                skillSnapshot: SystemPromptSkillRenderSnapshot(
                    activatedSkillNames: ["activated-only"],
                    skillsIndexDigest: auditA.product.skillSnapshot.skillsIndexDigest
                ),
                frozenSkillsIndexXML: contextA.frozenSkillsIndexXML
            ),
            effectiveUserSystemPrompt: auditA.effectiveUserSystemPrompt,
            providerStablePrefix: auditA.providerStablePrefix
        )
        let auditB = try await renderer.renderWithAudit(
            conversation: conv,
            policy: policy,
            userSystemPrompt: nil,
            assemblyContext: contextB,
            contributions: bundle.contributions,
            referenceDate: frozen,
            fullOverrideText: bundle.fullOverrideText
        )
        let iso = SystemPrompt.assembleReferenceDateISOString(from: frozen)
        let specSameIndexDiffActivation = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: iso,
            audit: auditAActivated,
            contributions: bundle.contributions
        )
        let specBase = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: iso,
            audit: auditA,
            contributions: bundle.contributions
        )
        let specOtherIndex = SystemPromptAssemblyReplayer.buildReplaySpec(
            assemblyFingerprint: "fp",
            assembleReferenceDateISO: iso,
            audit: auditB,
            contributions: bundle.contributions
        )
        #expect(specSameIndexDiffActivation.replaySpecDigest == specBase.replaySpecDigest)
        #expect(specOtherIndex.replaySpecDigest != specBase.replaySpecDigest)
    }

    @Test("Frozen skills index XML is preserved in conversation metadata merge")
    func metadataPreservesFrozenSkillsIndex() {
        let existing: JSON = .object([
            ConversationMetadataFrozenSkillsIndex.metadataKey: .string("<skills frozen/>"),
        ])
        let incoming: JSON = .object(["topic": .string("notes")])
        let merged = ConversationMetadataFrozenSkillsIndex.mergingPreservingFrozenSkillsIndex(
            existing: existing,
            incoming: incoming
        )
        #expect(ConversationMetadataFrozenSkillsIndex.frozenSkillsIndexXML(from: merged) == "<skills frozen/>")
    }

    @Test("Post-compaction re-injection applies per-skill and total skill budgets")
    func postCompactionSkillReinjectionUnderBudget() {
        var config = ContextCompactionConfiguration.default
        config.reinjectionPerSkillTokenBudget = 5_000
        config.reinjectionTotalSkillTokenBudget = 8_000
        let big = String(repeating: "z", count: 40_000)
        let messages = ContextCompactionReinjectionCollector.collectMessages(
            head: [],
            middle: [],
            tail: [],
            skills: [
                ReinjectableSkill(name: "alpha", content: big),
                ReinjectableSkill(name: "beta", content: big),
            ],
            instructionContext: nil,
            config: config
        )
        let skillMessages = messages.filter { $0.content.contains("active skill:") }
        #expect(skillMessages.count == 1)
        #expect(skillMessages.first?.content.contains("alpha") == true)
    }
}
