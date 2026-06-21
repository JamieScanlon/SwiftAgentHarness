import Foundation

/// Tiers for whether a slash command may run while the model is busy (server-side; exposed for list APIs and clients).
public enum SlashCommandBypassTier: String, Sendable, Equatable, Codable, CaseIterable {
    case always
    case connecting
    case immediateUI
    case sideEffectFree
    case queued
}

/// One row for REST/autocomplete; `name` is user-facing (includes a leading `/`).
public struct SlashCommandAutocompleteEntry: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var argumentHint: String?
    public var hiddenKeywords: String
    public var bypassTier: SlashCommandBypassTier

    public init(
        name: String,
        description: String,
        argumentHint: String? = nil,
        hiddenKeywords: String = "",
        bypassTier: SlashCommandBypassTier
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.hiddenKeywords = hiddenKeywords
        self.bypassTier = bypassTier
    }
}
