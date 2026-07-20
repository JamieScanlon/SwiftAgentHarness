import Foundation
import SwiftAgentKit
import Testing
import SwiftAgentKitOrchestrator
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("Cache expiry integration")
struct CacheExpiryIntegrationTests {
  @Test("applyLLMContextSnapshot records lastModelRequestAt per conversation")
  func poolRecordsLastModelRequestAt() async {
    let pool = OrchestratorPool()
    let conversationID = UUID()
    let modelName = "cache-expiry:test"
    let acquisition = await pool.acquire(conversationID: conversationID, modelName: modelName) {
      BuiltOrchestrator(
        orchestrator: SwiftAgentKitOrchestrator(
          llm: StubTurnLoopLLM(),
          config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        ),
        queuedLLM: QueuedLLM(baseLLM: StatefulLLM(baseLLM: StubTurnLoopLLM())),
        conversationID: conversationID
      )
    }
    #expect(acquisition != nil)
    #expect(await pool.lastModelRequestAt(for: conversationID) == nil)

    await pool.applyLLMContextSnapshot(
      for: conversationID,
      from: LLMResponse(content: "ok", toolCalls: []),
      requestConfig: LLMRequestConfig(maxTokens: 4096)
    )
    #expect(await pool.lastModelRequestAt(for: conversationID) != nil)
    if let acquisition {
      await pool.release(acquisition.handle)
    }
  }

  @Test("PromptCacheExpectsReadGate uses recent model request not compaction timing")
  func expectsReadUsesModelRequestAt() {
    TestTargetBootstrap.ensureProvidersRegistered()
    ProviderRegistry.ensureBootstrapped()
    let referenceInstant = Date(timeIntervalSince1970: 1_700_000_000)
    let recentModelRequest = referenceInstant.addingTimeInterval(-60)
    let plan = PromptCachePlan(
      mode: .persistent,
      stablePrefixMessageCount: 1,
      stablePrefixTokenEstimate: 100
    )
    let binding = ProviderBinding(
      providerId: "anthropic",
      modelProtocol: .anthropic,
      endpointModelId: "claude-sonnet-4-6",
      serverURL: URL(string: "https://api.anthropic.com")!
    )
    let messages = [
      Message(id: UUID(), role: .assistant, content: "prior", timestamp: referenceInstant, toolCalls: []),
      Message(id: UUID(), role: .user, content: "next", timestamp: referenceInstant, toolCalls: []),
    ]
    #expect(
      PromptCacheExpectsReadGate.evaluate(
        plan: plan,
        lastLLMDate: recentModelRequest,
        binding: binding,
        referenceInstant: referenceInstant,
        messages: messages
      )
    )
  }

  @Test("cacheExpiredHygieneWindow bypasses compaction LLM cooldown")
  func expiryBypassesCompactionCooldown() {
    var cfg = ContextCompactionConfiguration.default
    cfg.enabled = true
    cfg.proactiveOutputReserveTokens = 0
    cfg.proactiveSafetyBufferTokens = 20
    cfg.compactionLLMCooldownSeconds = 600
    let model = Model(
      id: UUID(),
      protocol: .openAIAPI,
      modelName: "m",
      serverURL: URL(string: "http://127.0.0.1:1")!,
      capabilities: [],
      modelProtocol: .openAIAPI,
      maxContextLength: 10_000
    )
    let messages = [
      Message(id: UUID(), role: .user, content: "hi", timestamp: Date(), toolCalls: []),
      Message(id: UUID(), role: .assistant, content: "yo", timestamp: Date(), toolCalls: []),
    ]
    let convo = ModelConversation(id: UUID(), model: model, messages: messages, systemPrompt: "s")
    let meta = ConversationTransformMetadata(
      conversationID: convo.id,
      modelID: model.id.uuidString,
      modelName: model.modelName,
      interactionMode: .chat,
      routingPolicyTools: [],
      routingPolicySkills: [],
      thinkingEnabled: false,
      reasoningEffort: nil,
      metadata: nil
    )
    let recentCompaction = [convo.id: Date()]
    let blocked = ContextCompactionInputBuilder.buildInitialPhaseInput(
      messages: messages,
      conversation: convo,
      transformMetadata: meta,
      compactionConfig: cfg,
      enableContextTransform: true,
      lastContextLimitTokens: 10_000,
      lastPromptTokens: nil,
      events: [],
      eventLogFrontier: 0,
      lastCompactionLLMDateByConversationID: recentCompaction,
      gating: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: false),
      cacheExpiredHygieneWindow: false
    )
    guard case .passthrough(let blockedReason) = blocked else {
      Issue.record("Expected cooldown passthrough, got \(blocked)")
      return
    }
    #expect(blockedReason == "context_compaction_gated_cooldown_or_min_chars")

    let allowed = ContextCompactionInputBuilder.buildInitialPhaseInput(
      messages: messages,
      conversation: convo,
      transformMetadata: meta,
      compactionConfig: cfg,
      enableContextTransform: true,
      lastContextLimitTokens: 10_000,
      lastPromptTokens: nil,
      events: [],
      eventLogFrontier: 0,
      lastCompactionLLMDateByConversationID: recentCompaction,
      gating: ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: false),
      cacheExpiredHygieneWindow: true
    )
    guard case .transform = allowed else {
      Issue.record("Expected expiry hygiene window to bypass cooldown, got \(allowed)")
      return
    }
  }

  @Test("DefaultContextEngine assemble flags cacheExpiredHygieneWindow after long idle gap")
  func assembleFlagsExpiredHygieneWindow() async {
    let engine = DefaultContextEngine(compactionCoordinator: nil, logger: nil)
    let conversationID = UUID()
    let referenceInstant = Date(timeIntervalSince1970: 1_700_000_000)
    let model = Model(
      id: UUID(),
      protocol: .openAIAPI,
      modelName: "m",
      serverURL: URL(string: "http://127.0.0.1:1")!,
      capabilities: [],
      modelProtocol: .openAIAPI,
      maxContextLength: 131_072
    )
    let messages = [
      Message(id: UUID(), role: .user, content: "resume", timestamp: referenceInstant, toolCalls: []),
    ]
    let conversation = ModelConversation(
      id: conversationID,
      model: model,
      messages: messages,
      systemPrompt: "system"
    )
    let pruningPolicy = ContextPruningPolicy(
      mode: .cacheTTL,
      ttlSeconds: 300,
      keepRecentToolResults: 5,
      targetTools: nil
    )
    let request = ContextEngineAssembleRequest(
      messages: messages,
      conversation: conversation,
      phase: .initial,
      gatingOverride: nil,
      compactionCustomInstructionsOverride: nil,
      enableContextTransform: false,
      compactionConfig: .default,
      transformMetadata: ConversationTransformMetadata(
        conversationID: conversationID,
        modelID: model.id.uuidString,
        modelName: model.modelName,
        interactionMode: .chat,
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
      lastModelRequestAtByConversationID: [
        conversationID: referenceInstant.addingTimeInterval(-CacheExpiryInference.defaultThresholdSeconds),
      ],
      lastCompactionLLMDateByConversationID: [:],
      persistCompactionCheckpoint: true,
      allowProactiveCompactionTriggers: true,
      compactionLockAlreadyHeldByCaller: false,
      derivedTailAtProjectionStart: 0,
      projectionPolicy: ContextEngineProjectionPolicyInput(contextPruningPolicy: pruningPolicy)
    )
    let result = await engine.assemble(request: request) { input in
      ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
    }
    #expect(result.cacheExpiredHygieneWindow == true)
  }
}
