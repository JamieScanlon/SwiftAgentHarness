import Foundation

/// Harness-aligned prompt section bucket consumed by ``SystemPrompt`` assembly.
public enum SystemPromptAssemblyKind: String, Sendable, Codable, Equatable, Hashable {
    case chat
    case planCollaboration
    case agentBuild
}

extension InteractionMode {
    var harnessAssemblyKind: SystemPromptAssemblyKind {
        switch self {
        case .chat: return .chat
        case .plan: return .planCollaboration
        case .agent: return .agentBuild
        }
    }
}
