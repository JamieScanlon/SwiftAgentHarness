import Foundation

/// Session facts for system-prompt assembly (not layer contributions).
public struct SystemPromptAssemblyContext: Sendable, Equatable {
    public var conversationID: String
    public var conversationStartDate: String
    public var referenceDate: Date
    public var userSystemPrompt: String
    public var workflowBlock: String
    public var memoryInjectionMode: String
    public var tier1MemoryContent: String?
    public var memorySnapshotGeneration: Int?
    public var includeAgentSkills: Bool
    public var includeToolGuidance: Bool
    public var subAgentContextPrompt: String?
    public var registryProfileID: String?
    public var modeCompactionLevel: String?
    /// Session-frozen skills index XML (stable prefix); set once per conversation.
    public var frozenSkillsIndexXML: String?
    /// Dispatch-only; never interpolated into the prompt template.
    public var assembledPromptDigest: String?

    public init(
        conversationID: String,
        conversationStartDate: String,
        referenceDate: Date = Date(),
        userSystemPrompt: String = "",
        workflowBlock: String = "",
        memoryInjectionMode: String = "on",
        tier1MemoryContent: String? = nil,
        memorySnapshotGeneration: Int? = nil,
        includeAgentSkills: Bool = true,
        includeToolGuidance: Bool = true,
        subAgentContextPrompt: String? = nil,
        registryProfileID: String? = nil,
        modeCompactionLevel: String? = nil,
        frozenSkillsIndexXML: String? = nil,
        assembledPromptDigest: String? = nil
    ) {
        self.conversationID = conversationID
        self.conversationStartDate = conversationStartDate
        self.referenceDate = referenceDate
        self.userSystemPrompt = userSystemPrompt
        self.workflowBlock = workflowBlock
        self.memoryInjectionMode = memoryInjectionMode
        self.tier1MemoryContent = tier1MemoryContent
        self.memorySnapshotGeneration = memorySnapshotGeneration
        self.includeAgentSkills = includeAgentSkills
        self.includeToolGuidance = includeToolGuidance
        self.subAgentContextPrompt = subAgentContextPrompt
        self.registryProfileID = registryProfileID
        self.modeCompactionLevel = modeCompactionLevel
        self.frozenSkillsIndexXML = frozenSkillsIndexXML
        self.assembledPromptDigest = assembledPromptDigest
    }
}
