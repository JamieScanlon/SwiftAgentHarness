import EasyJSON

/// POST `/api/conversations` request body.
struct ConvoRequest: Codable {
    /// Model addressing: UUID or registry slug (`endpointModelId`).
    let modelRef: String?
    let userSystemPrompt: String?
    let topic: String?
    let description: String?
    let metadata: JSON?
    /// `"chat"`, `"plan"`, or `"agent"`; defaults to chat when omitted.
    let interactionMode: String?
    /// Persisted mode profile id; when set without `interactionMode`, routing resolves policy from this id.
    let modeProfileID: String?
    /// Optional initial working directory (trusted workspace root) for the conversation; defaults to the env-derived cwd when omitted.
    let cwd: String?
}

struct UpdateConversationMetadataRequest: Codable {
    let topic: String?
    let description: String?
    let metadata: JSON?
    /// Optional: `"chat"`, `"plan"`, or `"agent"` to change interaction mode (updates stored agent phase accordingly).
    let interactionMode: String?
    /// Optional persisted registry pointer for mode behavior. Server stores the pointer verbatim.
    let modeProfileID: String?

    init(
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: String?,
        modeProfileID: String? = nil
    ) {
        self.topic = topic
        self.description = description
        self.metadata = metadata
        self.interactionMode = interactionMode
        self.modeProfileID = modeProfileID
    }
}
