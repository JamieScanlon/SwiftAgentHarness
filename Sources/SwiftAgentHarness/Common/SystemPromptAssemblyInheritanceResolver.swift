import Foundation

struct ResolvedParentSystemPromptAssembly: Sendable, Equatable {
    let assembledSystemPromptText: String
    let assembledPromptDigest: String
    let replaySpecDigest: String?
    let frozenSkillsIndexXML: String?
    let fingerprint: String?
}

enum SystemPromptAssemblyInheritanceResolver {
    static func resolve(
        parentConversationID: UUID,
        cachedArtifact: ContextEngineSystemPromptAssemblyArtifact?,
        parentEvents: [CachedConversationEvent],
        frontierEventID: Int?
    ) -> ResolvedParentSystemPromptAssembly? {
        if let cachedArtifact,
           let text = cachedArtifact.assembledSystemPromptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let digest = cachedArtifact.assembledPromptDigest
                ?? SystemPromptDispatchCodec.sha256Digest(of: text)
            return ResolvedParentSystemPromptAssembly(
                assembledSystemPromptText: text,
                assembledPromptDigest: digest,
                replaySpecDigest: cachedArtifact.replaySpecDigest,
                frozenSkillsIndexXML: cachedArtifact.frozenSkillsIndexXML,
                fingerprint: cachedArtifact.fingerprint
            )
        }
        guard let pair = SuiteCheckpointSupport.latestValidSystemPromptAssembly(
            events: parentEvents,
            frontierEventID: frontierEventID
        ) else {
            return nil
        }
        let wire = pair.wire
        if let text = wire.assembledPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let digest = wire.assembledPromptDigest ?? SystemPromptDispatchCodec.sha256Digest(of: text)
            return ResolvedParentSystemPromptAssembly(
                assembledSystemPromptText: text,
                assembledPromptDigest: digest,
                replaySpecDigest: wire.replaySpecDigest,
                frozenSkillsIndexXML: nil,
                fingerprint: wire.assemblyFingerprint
            )
        }
        return nil
    }
}
