import Foundation

public struct TriggerDelegateProfile: Codable, Sendable, Equatable {
    public var subagentType: String?
    public var agentID: String?
    public var context: SubAgentLaunchContext = .isolated
    public var runInBackground: Bool = true
    public var modelRef: String?
    public var taskDescription: String?
    public var userSystemPrompt: String?

    enum CodingKeys: String, CodingKey {
        case subagentType
        case agentID
        case agentId
        case context
        case runInBackground
        case modelRef
        case taskDescription
        case userSystemPrompt
    }

    public init(
        subagentType: String? = nil,
        agentID: String? = nil,
        context: SubAgentLaunchContext = .isolated,
        runInBackground: Bool = true,
        modelRef: String? = nil,
        taskDescription: String? = nil,
        userSystemPrompt: String? = nil
    ) {
        self.subagentType = subagentType
        self.agentID = agentID
        self.context = context
        self.runInBackground = runInBackground
        self.modelRef = modelRef
        self.taskDescription = taskDescription
        self.userSystemPrompt = userSystemPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
            ?? c.decodeIfPresent(String.self, forKey: .agentId)
        context = try c.decodeIfPresent(SubAgentLaunchContext.self, forKey: .context) ?? .isolated
        runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? true
        modelRef = try c.decodeIfPresent(String.self, forKey: .modelRef)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription)
        userSystemPrompt = try c.decodeIfPresent(String.self, forKey: .userSystemPrompt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(subagentType, forKey: .subagentType)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        try c.encode(context, forKey: .context)
        try c.encode(runInBackground, forKey: .runInBackground)
        try c.encodeIfPresent(modelRef, forKey: .modelRef)
        try c.encodeIfPresent(taskDescription, forKey: .taskDescription)
        try c.encodeIfPresent(userSystemPrompt, forKey: .userSystemPrompt)
    }
}

enum TriggerDelegateProfileCodec {
    static func encodeToMetadata(_ profile: TriggerDelegateProfile?) -> String? {
        guard let profile else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profile) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeFromMetadata(_ raw: String?) -> TriggerDelegateProfile? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TriggerDelegateProfile.self, from: data)
    }
}
