import Foundation

public struct ProviderAuthOnboardingContext: Sendable {
    public var providerID: ProviderID
    public var authChoice: ProviderAuthChoice
    public var redirectReceiver: OAuthCallbackDelivery?

    public init(
        providerID: ProviderID,
        authChoice: ProviderAuthChoice,
        redirectReceiver: OAuthCallbackDelivery? = nil
    ) {
        self.providerID = providerID
        self.authChoice = authChoice
        self.redirectReceiver = redirectReceiver
    }
}

public protocol ProviderAuthOnboarding: Sendable {
    func onboard(_ context: ProviderAuthOnboardingContext) async throws -> AuthProfile
}

public extension TextInferenceProviding {
    var authOnboarding: (any ProviderAuthOnboarding)? { nil }
}
