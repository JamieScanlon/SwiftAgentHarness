import Foundation

extension SlashCommandDispatchService {
    func runSlashMemoryCommand(conversationID: UUID, filename: String?) async throws -> ChatStreamResponse {
        guard let memoryService = (deps.contextEngine as? DefaultContextEngine)?.memoryService else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Memory layer is not available."
            )
        }
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID),
              let cwd = conv.harnessPersistenceCwd else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "No workspace directory is set for this conversation."
            )
        }
        let context = try memoryService.makeSessionContext(conversationID: conversationID, cwd: cwd)
        _ = try await memoryService.bootstrapSession(context: context)
        let resolvedFilename = (filename?.isEmpty == false) ? filename! : "MEMORY.md"
        let targetPath: String
        do {
            targetPath = try WorkspacePathPolicy.resolveMemoryRelativePath(
                raw: resolvedFilename,
                memoryDirectory: context.memoryDirectory,
                requireExists: true
            )
        } catch {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "Memory path not allowed: \(resolvedFilename)"
            )
        }
        // openFileForEdit assumes a co-located client surface (desktop app); remote clients ignore or handle filePath locally.
        let intent = ClientSurfaceIntent(
            kind: .openFileForEdit,
            filePath: targetPath,
            scope: "memory",
            label: resolvedFilename
        )
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: "Opening memory file for edit: \(resolvedFilename)",
            surfaceIntents: [intent]
        )
    }

    func runSlashInitCommand(conversationID: UUID) async throws -> ChatStreamResponse {
        guard let conv = await deps.persistenceDomain.modelConversation(id: conversationID),
              let cwd = conv.harnessPersistenceCwd else {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "No workspace directory is set for this conversation."
            )
        }
        let agentsPath = (cwd as NSString).appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: agentsPath) {
            return try await deliverSyntheticSlashAssistantResponse(
                conversationID: conversationID,
                content: "AGENTS.md already exists at \(agentsPath)"
            )
        }
        let template = """
# Project instructions

Describe commands, architecture, and non-obvious gotchas the agent would get wrong without reading the code.

## Build and test

## Conventions

"""
        try template.write(toFile: agentsPath, atomically: true, encoding: .utf8)
        return try await deliverSyntheticSlashAssistantResponse(
            conversationID: conversationID,
            content: "Created starter AGENTS.md at \(agentsPath). Edit it with project-specific guidance."
        )
    }
}
