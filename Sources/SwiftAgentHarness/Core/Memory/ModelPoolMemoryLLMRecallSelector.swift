import CryptoKit
import Foundation
import Logging
import SwiftAgentKit

struct ModelPoolMemoryLLMRecallSelector: MemoryLLMRecallSelecting {
    private let scheduler: any ModelCallScheduling
    private let modelName: String
    private let serverURL: URL
    private let logger: Logger?

    init(
        scheduler: any ModelCallScheduling,
        modelName: String,
        serverURL: URL,
        logger: Logger? = nil
    ) {
        self.scheduler = scheduler
        self.modelName = modelName
        self.serverURL = serverURL
        self.logger = logger
    }

    func selectRelevantFiles(request: MemoryRecallRequest) async throws -> [String] {
        let manifestLines = request.manifestEntries.map(MemoryManifestScanner.formatManifestLine)
        guard !manifestLines.isEmpty else { return [] }
        let system = Message(
            id: UUID(),
            role: .system,
            content: """
You select memory topic files relevant to the user's query.
Return JSON only: {"filenames":["file1.md"]}
Be selective; if unsure, omit a file. At most 5 filenames.
Only use filenames from the manifest below.
"""
        )
        let user = Message(
            id: UUID(),
            role: .user,
            content: """
User query:
\(request.userQuery)

Memory manifest (headers only):
\(manifestLines.joined(separator: "\n"))
"""
        )
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true,
            logger: logger,
            interactionMode: .chat
        )
        let base = OllamaLLM(
            model: modelName,
            serverURL: serverURL,
            capabilities: [.completion],
            systemPrompt: prompt,
            logger: logger
        )
        let llm = SchedulingLLM(
            baseLLM: base,
            scheduler: scheduler,
            modelID: Self.modelID(model: modelName, serverURL: serverURL),
            priority: .background
        )
        let response = try await llm.send([system, user], config: .harnessTagged(.memoryRecallSelector))
        return Self.parseFilenames(from: response.content, allowed: Set(request.manifestEntries.map(\.filename)))
    }

    static func modelID(model: String, serverURL: URL) -> UUID {
        let modelToken = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let endpointToken = serverURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "memory-recall-selector|\(endpointToken)|\(modelToken)"
        let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
            (digest[6] & 0x0F) | 0x50, digest[7], (digest[8] & 0x3F) | 0x80,
            digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    static func parseFilenames(from content: String, allowed: Set<String>) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = object["filenames"] as? [String] else {
            return []
        }
        return names.filter { allowed.contains($0) }.prefix(5).map { $0 }
    }
}
