import Foundation

/// Policy evaluation context tying persisted conversation mode to a **resolved registry profile**.
///
/// Tool/skill allowlists remain keyed by ``InteractionMode``; ``ModeProfileToolsSlice`` composes
/// an additional intersection gate per ``modes.md``. ``registryProfileId`` mirrors ``resolvedProfile/id``.
public struct ModePolicyContext: Sendable, Equatable {
    public var interactionMode: InteractionMode
    public var resolvedProfile: ResolvedModeProfile

    public var registryProfileId: String { resolvedProfile.id }

    public init(interactionMode: InteractionMode, resolvedProfile: ResolvedModeProfile) {
        self.interactionMode = interactionMode
        self.resolvedProfile = resolvedProfile
    }

    public init(conversation: ModelConversation, resolvedProfile: ResolvedModeProfile) {
        self.interactionMode = conversation.interactionMode
        self.resolvedProfile = resolvedProfile
    }
}
