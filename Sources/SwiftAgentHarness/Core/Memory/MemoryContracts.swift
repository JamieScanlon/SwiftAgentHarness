import Foundation
import SwiftAgentKit

enum MemoryChatType: String, Sendable, Codable, Equatable {
    case direct
    case group
    case channel
}

struct MemorySessionContext: Sendable, Equatable {
    let conversationID: UUID
    let cwd: String
    let canonicalGitRoot: String?
    let memoryDirectory: URL
    let userMemoryDirectory: URL
    let chatType: MemoryChatType
    let agentID: String?

    init(
        conversationID: UUID,
        cwd: String,
        canonicalGitRoot: String?,
        memoryDirectory: URL,
        userMemoryDirectory: URL? = nil,
        chatType: MemoryChatType = .direct,
        agentID: String? = nil
    ) {
        self.conversationID = conversationID
        self.cwd = cwd
        self.canonicalGitRoot = canonicalGitRoot
        self.memoryDirectory = memoryDirectory
        if let userMemoryDirectory {
            self.userMemoryDirectory = userMemoryDirectory
        } else if let resolved = try? AgentMemoryPathResolver.resolveUserMemoryDirectory() {
            self.userMemoryDirectory = resolved
        } else {
            self.userMemoryDirectory = memoryDirectory.appendingPathComponent("_user-tier", isDirectory: true)
        }
        self.chatType = chatType
        self.agentID = agentID
    }
}

struct MemorySystemPromptBlocks: Sendable, Equatable {
    let projectInstructionsText: String
    let memoryIndexText: String
    let recalledTopicBodiesText: String
    let taxonomyPromptText: String
    let driftGuardText: String
    let sensitiveDataPromptText: String
    let memoryPathDisclosureText: String
    let snapshotGeneration: Int

    var combinedSystemPromptSection: String {
        [projectInstructionsText, memoryPathDisclosureText, memoryIndexText, recalledTopicBodiesText,
         taxonomyPromptText, driftGuardText, sensitiveDataPromptText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var stableSystemPromptSection: String {
        [projectInstructionsText, memoryPathDisclosureText, memoryIndexText,
         taxonomyPromptText, driftGuardText, sensitiveDataPromptText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

struct MemoryRecallRequest: Sendable {
    let session: MemorySessionContext
    let userQuery: String
    let manifestEntries: [MemoryManifestEntry]
}

struct MemoryRecallHit: Sendable, Equatable {
    let selectionKey: String
    /// Scope tag + body; not yet fenced (Context Engine applies injection policy).
    let formattedBody: String
}

struct MemoryRecallResult: Sendable, Equatable {
    let selectedFilenames: [String]
    let hits: [MemoryRecallHit]

    var recalledBodiesText: String {
        let bodies = hits.map(\.formattedBody).filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return "" }
        return MemoryContextFencer.fence(bodies.joined(separator: "\n\n"))
    }

    init(selectedFilenames: [String], hits: [MemoryRecallHit]) {
        self.selectedFilenames = selectedFilenames
        self.hits = hits
    }

    init(selectedFilenames: [String], recalledBodiesText: String) {
        self.selectedFilenames = selectedFilenames
        if recalledBodiesText.isEmpty {
            self.hits = []
        } else {
            self.hits = [MemoryRecallHit(selectionKey: "", formattedBody: recalledBodiesText)]
        }
    }
}

struct MemoryTurnEndedRequest: Sendable {
    let session: MemorySessionContext
    let mainAgentWroteMemory: Bool
    let isMainREPLThread: Bool
    let recentMessageCount: Int
    let anchorUserMessageID: UUID?
    let recentMessages: [Message]

    init(
        session: MemorySessionContext,
        mainAgentWroteMemory: Bool,
        isMainREPLThread: Bool,
        recentMessageCount: Int,
        anchorUserMessageID: UUID? = nil,
        recentMessages: [Message] = []
    ) {
        self.session = session
        self.mainAgentWroteMemory = mainAgentWroteMemory
        self.isMainREPLThread = isMainREPLThread
        self.recentMessageCount = recentMessageCount
        self.anchorUserMessageID = anchorUserMessageID
        self.recentMessages = recentMessages
    }
}

protocol ActiveMemoryPreReplyRunning: Sendable {
    func blockingRecallSummary(
        session: MemorySessionContext,
        userQuery: String?,
        lane: RecallLane,
        timeoutMs: Int,
        maxSummaryChars: Int,
        excludedSelectionKeys: Set<String>
    ) async -> String?
}

protocol MemoryExtractionRunning: Sendable {
    func startBackgroundExtraction(request: MemoryTurnEndedRequest) async
}

struct MemorySubAgentSpawnPort: Sendable {
    var spawnBlockingRecall: @Sendable (
        _ parentConversationID: UUID,
        _ userQuery: String?,
        _ lane: RecallLane,
        _ timeoutMs: Int,
        _ maxSummaryChars: Int,
        _ excludedSelectionKeys: Set<String>
    ) async -> String?

    var spawnBackgroundExtraction: @Sendable (_ request: MemoryTurnEndedRequest) async -> Void

    var spawnBlockingPreCompactionFlush: @Sendable (
        _ parentConversationID: UUID,
        _ middleMessages: [Message],
        _ timeoutMs: Int
    ) async -> Bool
}

protocol MemoryServicing: Sendable {
    func bootstrapSession(context: MemorySessionContext) async throws -> MemorySystemPromptBlocks
    func systemPromptBlocks(conversationID: UUID) async -> MemorySystemPromptBlocks?
    func recallForTurn(request: MemoryRecallRequest) async throws -> MemoryRecallResult
    func onTurnEnded(request: MemoryTurnEndedRequest) async
    func onPreCompress(conversationID: UUID, messages: [String]) async throws
    func drainPendingWork(timeoutMs: Int) async
    func shutdown() async
    func invalidateSnapshot(conversationID: UUID) async
    func endSession(conversationID: UUID) async
    func currentSnapshotGeneration(conversationID: UUID) async -> Int
}

protocol MemoryWriteObserving: Sendable {
    func recordMainAgentWrite(path: String, conversationID: UUID) async
    func recordAuxiliaryWrite(path: String, conversationID: UUID) async
    func hadMainAgentWrites(conversationID: UUID) async -> Bool
    func hadWrites(conversationID: UUID) async -> Bool
    func mainAgentWrittenPaths(conversationID: UUID) async -> [String]
    func auxiliaryWrittenPaths(conversationID: UUID) async -> [String]
    func writtenPaths(conversationID: UUID) async -> [String]
    func resetTurn(conversationID: UUID) async
}

protocol MemoryProviding: Sendable {
    func initialize(sessionID: UUID, context: MemorySessionContext) async throws
    func systemPromptBlock() async -> String
    func prefetch(query: String) async -> String?
    func queuePrefetch(query: String) async
    func syncTurn(userContent: String, assistantContent: String) async
    func onPreCompress(messages: [String]) async -> String
    func onSessionEnd(messages: [String]) async
    func shutdown() async
}

struct MemoryManifestEntry: Sendable, Equatable {
    let filename: String
    let memoryType: MemoryTopicType
    let name: String
    let description: String
    let updatedAt: Date?
    let tierScope: MemoryTierScope

    init(
        filename: String,
        memoryType: MemoryTopicType,
        name: String,
        description: String,
        updatedAt: Date?,
        tierScope: MemoryTierScope = .project
    ) {
        self.filename = filename
        self.memoryType = memoryType
        self.name = name
        self.description = description
        self.updatedAt = updatedAt
        self.tierScope = tierScope
    }

    var selectionKey: String {
        tierScope == .user ? "user/\(filename)" : filename
    }
}

enum MemoryTierScope: String, Sendable, Equatable {
    case user
    case project
}

enum MemoryTopicType: String, Sendable, Codable, Equatable, CaseIterable {
    case user
    case feedback
    case project
    case reference
}

enum RecallLane: String, Sendable, Hashable {
    /// Query-independent: user profile + stable preferences. Warmed at session start.
    case standing
    /// Query-dependent: project/reference context. Warmed on arrival, keyed on query.
    case situational
}

enum MemoryPathValidationError: Error, Equatable {
    case relativePath
    case rootOrNearRoot
    case uncPath
    case nullByte
    case unsafeTildeExpansion
    case invalidPath(String)
}
