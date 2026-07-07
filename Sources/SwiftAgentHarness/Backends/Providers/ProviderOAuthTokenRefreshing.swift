import Foundation

public protocol ProviderOAuthTokenRefreshing: Sendable {
    func refreshAccessToken(profile: AuthProfile, scopes: [String]) async throws -> AuthProfile
}

public struct NoOpOAuthTokenRefresher: ProviderOAuthTokenRefreshing {
    public init() {}

    public func refreshAccessToken(profile: AuthProfile, scopes: [String]) async throws -> AuthProfile {
        let _ = scopes
        throw AuthProfileStoreError.refreshNotImplemented(profile.providerID)
    }
}
