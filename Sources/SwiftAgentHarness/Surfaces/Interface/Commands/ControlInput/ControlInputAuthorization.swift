import Foundation

public enum AuthorizationDecision: Sendable, Equatable {
    case allow
    case fallThroughToPlainText
}

/// Authorization context for privileged control input at the surface boundary.
public struct ControlInputAuthorization: Sendable, Equatable {
    public var isOwner: Bool
    public var trustClass: TrustPolicyClass
    public var allowlistAllows: Bool

    public init(
        isOwner: Bool = true,
        trustClass: TrustPolicyClass = .trusted,
        allowlistAllows: Bool = true
    ) {
        self.isOwner = isOwner
        self.trustClass = trustClass
        self.allowlistAllows = allowlistAllows
    }

    public var allowsPrivilegedInput: Bool {
        trustClass == .trusted && (isOwner || allowlistAllows)
    }

    public func authorize(command: SlashCommand) -> AuthorizationDecision {
        guard allowsPrivilegedInput else { return .fallThroughToPlainText }
        if command.base.ownerOnly, !isOwner { return .fallThroughToPlainText }
        return .allow
    }

    public func authorizeDirectives() -> AuthorizationDecision {
        allowsPrivilegedInput ? .allow : .fallThroughToPlainText
    }

    public func authorizeShortcuts() -> AuthorizationDecision {
        allowsPrivilegedInput ? .allow : .fallThroughToPlainText
    }
}
