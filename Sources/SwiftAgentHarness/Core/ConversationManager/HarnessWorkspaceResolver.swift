import Foundation

/// Controls when sanctioned ambient workspace discovery may backfill ``ModelConversation/harnessPersistenceCwd``.
public struct HarnessWorkspacePolicy: Sendable, Equatable {
    public var allowAmbientWorkspaceFallback: Bool

    public static let `default` = HarnessWorkspacePolicy(allowAmbientWorkspaceFallback: false)

    public init(allowAmbientWorkspaceFallback: Bool) {
        self.allowAmbientWorkspaceFallback = allowAmbientWorkspaceFallback
    }
}

/// Resolves conversation workspace roots without silent ambient fallbacks at use time.
enum HarnessWorkspaceResolver {
    static func normalizedCwd(_ cwd: String?) -> String? {
        guard let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Sanctioned ambient chain used at conversation creation and opt-in CLI hosts.
    static func ambientIfKnown(fileManager: FileManager = .default) -> String? {
        if let v = ProcessInfo.processInfo.environment["SAH_SESSION_CWD"], !v.isEmpty {
            return normalizedCwd(v)
        }
        if let v = ProcessInfo.processInfo.environment["PWD"], !v.isEmpty {
            return normalizedCwd(v)
        }
        let cur = fileManager.currentDirectoryPath
        if cur.isEmpty || cur == "/" { return nil }
        return normalizedCwd(cur)
    }

    static func recordedCwd(on conversation: ModelConversation) -> String? {
        normalizedCwd(conversation.harnessPersistenceCwd)
    }

    /// Read-only prompt assembly: recorded workspace only; never ambient.
    static func resolveForPromptContext(conversation: ModelConversation) -> String? {
        recordedCwd(on: conversation)
    }

    /// Side-effecting paths: recorded cwd, or sanctioned ambient when policy allows.
    static func resolveForSideEffects(
        conversation: ModelConversation,
        policy: HarnessWorkspacePolicy,
        fileManager: FileManager = .default
    ) throws -> String {
        if let recorded = recordedCwd(on: conversation) {
            return recorded
        }
        guard policy.allowAmbientWorkspaceFallback,
              let ambient = ambientIfKnown(fileManager: fileManager) else {
            throw ConversationServiceError.harnessWorkspaceNotRecorded(conversationID: conversation.id)
        }
        return ambient
    }
}
