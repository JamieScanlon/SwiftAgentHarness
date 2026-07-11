import CryptoKit
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("MemoryInjectionSnapshot Tier-2 projection cache")
struct MemoryInjectionSnapshotCacheTests {
  @Test("Replays reuse recallHits and skip selector; new user message or store bump re-selects")
  func tier2ProjectionCacheRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mi6-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let countingRuntime = CountingRecallRuntime(config: .default)
    let service = DefaultMemoryService(
      config: .default,
      userConfigDir: root.appendingPathComponent("user", isDirectory: true)
    )
    await service.registerActiveMemoryCapability(
      MemoryCapability(pluginID: "counting-file-store", runtime: countingRuntime)
    )

    let engine = DefaultContextEngine(compactionCoordinator: nil, memoryService: service, logger: nil)
    var conv = ModelConversation(
      model: Model(
        protocol: .openAIAPI,
        modelName: "x",
        serverURL: URL(string: "http://localhost:1")!,
        capabilities: [.completion],
        modelProtocol: .openAIAPI,
        maxContextLength: 200_000
      ),
      messages: [],
      systemPrompt: "s"
    )
    conv.harnessPersistenceCwd = root.path
    let context = try service.makeSessionContext(conversationID: conv.id, cwd: root.path)
    _ = try await service.bootstrapSession(context: context)
    try """
    ---
    name: Cache Topic
    description: cache topic oversized recall body for selector
    type: project
    ---
    cached memory body for projection reuse
    """.write(
      to: context.memoryDirectory.appendingPathComponent("cache-topic.md"),
      atomically: true,
      encoding: .utf8
    )

    let systemID = UUID()
    let userID = UUID()
    let baseMessages: [Message] = [
      Message(id: systemID, role: .system, content: "system", timestamp: Date(), toolCalls: []),
      Message(id: userID, role: .user, content: "cache topic oversized recall body", timestamp: Date(), toolCalls: []),
    ]
    let metadata = ConversationTransformMetadata(
      conversationID: conv.id,
      modelID: conv.model.id.uuidString,
      modelName: conv.model.modelName,
      interactionMode: .chat,
      routingPolicyTools: [],
      routingPolicySkills: [],
      thinkingEnabled: false,
      reasoningEffort: nil,
      metadata: nil
    )
    let transform: @Sendable (ContextTransformInput) async throws -> ContextTransformOutput = { input in
      ContextTransformOutput(messages: input.messages, diagnostics: nil, messageProvenance: nil)
    }

    var request = ContextEngineAssembleRequest(
      messages: baseMessages,
      conversation: conv,
      phase: .initial,
      gatingOverride: nil,
      compactionCustomInstructionsOverride: nil,
      enableContextTransform: true,
      compactionConfig: .default,
      transformMetadata: metadata,
      lastContextLimitTokens: 200_000,
      lastPromptTokens: 100,
      events: [],
      eventLogFrontier: 0,
      lastLLMDateByConversationID: [:],
      persistCompactionCheckpoint: false,
      allowProactiveCompactionTriggers: true,
      compactionLockAlreadyHeldByCaller: false,
      derivedTailAtProjectionStart: 0
    )

    let turn1 = await engine.assemble(request: request, performTransform: transform)
    #expect(turn1.projectedMemorySelectionKeys.contains("cache-topic.md"))
    #expect(await countingRuntime.recallForTurnCountSnapshot() == 1)
    #expect(await countingRuntime.recallHitsCountSnapshot() == 0)

    let snapshotSpec = try #require(turn1.memoryInjectionSnapshot)
    let selectorFingerprint = await service.recallSelectorConfigFingerprint()
    let storeVersion = await service.currentSnapshotGeneration(conversationID: conv.id)
    let recallEntryID = tier2RecallHarnessEntryID(generation: max(storeVersion, 1))
    let selectedKeys = snapshotSpec.selectedSelectionKeys
    let projectedKeys = snapshotSpec.projectedSelectionKeys
    let snapshotJSONData = try JSONEncoder().encode(
      MemoryStoreSnapshotJSON(
        memoryEntryIDs: [recallEntryID],
        memoryStoreVersion: snapshotSpec.memoryStoreVersion,
        selectedSelectionKeys: selectedKeys,
        projectedSelectionKeys: projectedKeys
      )
    )
    let snapshotJSON = try #require(String(data: snapshotJSONData, encoding: .utf8))
    let fingerprintInput = MemoryInjectionSnapshotProjectionPolicy.injectionFingerprintInput(
      phaseRaw: "initial",
      conversationID: conv.id,
      memoryStoreVersion: snapshotSpec.memoryStoreVersion,
      injectedMemoryEntryIDs: [recallEntryID],
      selectedSelectionKeys: selectedKeys,
      projectedSelectionKeys: projectedKeys,
      selectionContextMessageIDs: baseMessages.map(\.id),
      selectorConfigFingerprint: selectorFingerprint
    )
    let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let wire = MemoryInjectionSnapshotCheckpointWire(
      schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
      basedOnEventID: 1,
      injectionFingerprint: fingerprint,
      snapshotJSON: snapshotJSON,
      scopeMessageIDs: [recallEntryID],
      memoryStoreVersion: snapshotSpec.memoryStoreVersion,
      memoryStoreNamespaceKey: conv.id.uuidString,
      memoryEntryIDs: [recallEntryID],
      selectorConfigFingerprint: selectorFingerprint,
      selectionContextMessageIDs: baseMessages.map(\.id),
      createdAt: Date()
    )
    let checkpointEvent = CachedConversationEvent(
      conversationID: conv.id,
      eventID: 1,
      kind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
      payloadJSON: ConversationEventCodec.encode(wire),
      createdAt: Date()
    )

    request = ContextEngineAssembleRequest(
      messages: baseMessages,
      conversation: conv,
      phase: .initial,
      gatingOverride: nil,
      compactionCustomInstructionsOverride: nil,
      enableContextTransform: true,
      compactionConfig: .default,
      transformMetadata: metadata,
      lastContextLimitTokens: 200_000,
      lastPromptTokens: 100,
      events: [checkpointEvent],
      eventLogFrontier: 1,
      lastLLMDateByConversationID: [:],
      persistCompactionCheckpoint: false,
      allowProactiveCompactionTriggers: true,
      compactionLockAlreadyHeldByCaller: false,
      derivedTailAtProjectionStart: 1
    )
    let turn2 = await engine.assemble(request: request, performTransform: transform)
    #expect(turn2.projectedMemorySelectionKeys.contains("cache-topic.md"))
    #expect(await countingRuntime.recallForTurnCountSnapshot() == 1)
    #expect(await countingRuntime.recallHitsCountSnapshot() == 1)

    let newUserID = UUID()
    let extendedMessages = baseMessages + [
      Message(id: newUserID, role: .user, content: "another cache topic question", timestamp: Date(), toolCalls: []),
    ]
    request = ContextEngineAssembleRequest(
      messages: extendedMessages,
      conversation: conv,
      phase: .initial,
      gatingOverride: nil,
      compactionCustomInstructionsOverride: nil,
      enableContextTransform: true,
      compactionConfig: .default,
      transformMetadata: metadata,
      lastContextLimitTokens: 200_000,
      lastPromptTokens: 100,
      events: [checkpointEvent],
      eventLogFrontier: 1,
      lastLLMDateByConversationID: [:],
      persistCompactionCheckpoint: false,
      allowProactiveCompactionTriggers: true,
      compactionLockAlreadyHeldByCaller: false,
      derivedTailAtProjectionStart: 1
    )
    _ = await engine.assemble(request: request, performTransform: transform)
    #expect(await countingRuntime.recallForTurnCountSnapshot() == 2)
    #expect(await countingRuntime.recallHitsCountSnapshot() == 1)

    let invalidatedEvent = CachedConversationEvent(
      conversationID: conv.id,
      eventID: 2,
      kind: ConversationEventKind.checkpointInvalidated.rawValue,
      payloadJSON: ConversationEventCodec.encode(
        CheckpointInvalidatedEventPayload(kinds: [HarnessCheckpointInvalidationKind.memoryInjectionSnapshot])
      ),
      createdAt: Date()
    )
    request = ContextEngineAssembleRequest(
      messages: baseMessages,
      conversation: conv,
      phase: .initial,
      gatingOverride: nil,
      compactionCustomInstructionsOverride: nil,
      enableContextTransform: true,
      compactionConfig: .default,
      transformMetadata: metadata,
      lastContextLimitTokens: 200_000,
      lastPromptTokens: 100,
      events: [checkpointEvent, invalidatedEvent],
      eventLogFrontier: 2,
      lastLLMDateByConversationID: [:],
      persistCompactionCheckpoint: false,
      allowProactiveCompactionTriggers: true,
      compactionLockAlreadyHeldByCaller: false,
      derivedTailAtProjectionStart: 2
    )
    _ = await engine.assemble(request: request, performTransform: transform)
    #expect(await countingRuntime.recallForTurnCountSnapshot() == 3)
    #expect(await countingRuntime.recallHitsCountSnapshot() == 1)
  }
}

private actor CountingRecallRuntime: MemoryRuntime {
  private let inner: FileStoreMemoryBackend
  private var recallForTurnCount = 0
  private var recallHitsCount = 0

  init(config: MemoryConfiguration) {
    inner = FileStoreMemoryBackend(config: config, llmRecallSelector: nil)
  }

  func recallForTurnCountSnapshot() async -> Int { recallForTurnCount }
  func recallHitsCountSnapshot() async -> Int { recallHitsCount }

  func initialize(sessionID: UUID, context: MemorySessionContext) async throws {
    try await inner.initialize(sessionID: sessionID, context: context)
  }

  func endSession(conversationID: UUID) async {
    await inner.endSession(conversationID: conversationID)
  }

  func shutdown() async {
    await inner.shutdown()
  }

  func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult {
    recallForTurnCount += 1
    return try await inner.recallForTurn(request: request)
  }

  func recallHits(selectionKeys: [String], session: MemorySessionContext) async throws -> MemoryRecallResult {
    recallHitsCount += 1
    return try await inner.recallHits(selectionKeys: selectionKeys, session: session)
  }

  func onTurnEnded(request: MemoryTurnEndedRequest) async {
    await inner.onTurnEnded(request: request)
  }

  func onPreCompress(messages: [String]) async -> String {
    await inner.onPreCompress(messages: messages)
  }

  func refreshSnapshotAfterFlush(conversationID: UUID) async throws {
    try await inner.refreshSnapshotAfterFlush(conversationID: conversationID)
  }

  func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks? {
    await inner.systemPromptBlocks(conversationID: conversationID)
  }

  func currentSnapshotGeneration(conversationID: UUID) async -> Int {
    await inner.currentSnapshotGeneration(conversationID: conversationID)
  }

  func invalidateSnapshot(conversationID: UUID) async {
    await inner.invalidateSnapshot(conversationID: conversationID)
  }

  func manifestEntries(conversationID: UUID) async -> [MemoryManifestEntry] {
    await inner.manifestEntries(conversationID: conversationID)
  }

  func hybridSearch() async -> HybridMemorySearch {
    await inner.hybridSearch()
  }

  func updateSnapshot(
    conversationID: UUID,
    blocks: MemorySystemPromptBlocks,
    manifest: [MemoryManifestEntry]
  ) async {
    await inner.updateSnapshot(conversationID: conversationID, blocks: blocks, manifest: manifest)
  }

  func runDreamingSweep(memoryDirectory: URL, rollback: Bool) async throws {
    try await inner.runDreamingSweep(memoryDirectory: memoryDirectory, rollback: rollback)
  }

  func bindSpawnPort(_ port: MemorySubAgentSpawnPort) async {
    await inner.bindSpawnPort(port)
  }

  func drainPendingWork(timeoutMs: Int) async {
    await inner.drainPendingWork(timeoutMs: timeoutMs)
  }

  func store(for conversationID: UUID) async -> AgentMemoryStore? {
    await inner.store(for: conversationID)
  }

  func sessionContext(for conversationID: UUID) async -> MemorySessionContext? {
    await inner.sessionContext(for: conversationID)
  }

  func activeRecallSummary(
    session: MemorySessionContext,
    messages: [Message],
    anchorUserMessageID: UUID?,
    sessionEnabled: Bool,
    excludedSelectionKeys: Set<String>
  ) async -> ActiveMemoryRecallOutcome {
    await inner.activeRecallSummary(
      session: session,
      messages: messages,
      anchorUserMessageID: anchorUserMessageID,
      sessionEnabled: sessionEnabled,
      excludedSelectionKeys: excludedSelectionKeys
    )
  }

  func warmStandingRecall(session: MemorySessionContext, sessionEnabled: Bool) async {
    await inner.warmStandingRecall(session: session, sessionEnabled: sessionEnabled)
  }

  func prefetchSituationalRecall(
    session: MemorySessionContext,
    messages: [Message],
    anchorUserMessageID: UUID?,
    sessionEnabled: Bool
  ) async {
    await inner.prefetchSituationalRecall(
      session: session,
      messages: messages,
      anchorUserMessageID: anchorUserMessageID,
      sessionEnabled: sessionEnabled
    )
  }

  func invalidateStandingRecall(conversationID: UUID) async {
    await inner.invalidateStandingRecall(conversationID: conversationID)
  }
}

private func tier2RecallHarnessEntryID(generation: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-4000-9000-%012x", generation)) ?? UUID()
}
