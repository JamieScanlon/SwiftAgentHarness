import Foundation
import Testing
import Vapor
@testable import SwiftAgentHarness

@Suite("API access token authentication")
struct APIAccessTokenAuthenticationTests {
    private static let settings = APIAccessTokenAuthenticationSettings(hs256Secret: "unit-test-secret")

    @Test("Minted bearer JWT resolves owner from sub claim")
    func mintAndValidateHappyPath() async throws {
        let owner = UUID()
        let token = try await HarnessAPIAccessTokenFactory.mint(
            ownerAccountID: owner,
            settings: Self.settings
        )
        let validator = JWTAPIAccessTokenValidator(settings: Self.settings)
        let resolved = try validator.validatedOwnerAccountID(bearerToken: token)
        #expect(resolved == owner)
    }

    @Test("Expired bearer JWT is rejected")
    func expiredTokenRejected() async throws {
        let owner = UUID()
        let token = try await HarnessAPIAccessTokenFactory.mint(
            ownerAccountID: owner,
            settings: Self.settings,
            expiresAt: Date().addingTimeInterval(-60)
        )
        let validator = JWTAPIAccessTokenValidator(settings: Self.settings)
        #expect(throws: APIAccessTokenValidationError.self) {
            try validator.validatedOwnerAccountID(bearerToken: token)
        }
    }

    @Test("Wrong secret rejects bearer JWT")
    func badSignatureRejected() async throws {
        let owner = UUID()
        let token = try await HarnessAPIAccessTokenFactory.mint(
            ownerAccountID: owner,
            settings: Self.settings
        )
        let validator = JWTAPIAccessTokenValidator(
            settings: APIAccessTokenAuthenticationSettings(hs256Secret: "other-secret")
        )
        #expect(throws: APIAccessTokenValidationError.self) {
            try validator.validatedOwnerAccountID(bearerToken: token)
        }
    }

    @Test("Legacy X-SAH-Authenticated-Owner header is ignored when validator is configured")
    func legacyOwnerHeaderIgnored() {
        let owner = UUID()
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "X-SAH-Authenticated-Owner", value: owner.uuidString)
        let validator = JWTAPIAccessTokenValidator(settings: Self.settings)
        let resolved = APISessionAuthenticatedOwnerResolver.resolve(from: headers, validator: validator)
        #expect(resolved == nil)
    }

    @Test("Bearer resolver ignores malformed Authorization header")
    func malformedAuthorizationIgnored() {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .authorization, value: "Token abc")
        let validator = JWTAPIAccessTokenValidator(settings: Self.settings)
        let resolved = APISessionAuthenticatedOwnerResolver.resolve(from: headers, validator: validator)
        #expect(resolved == nil)
    }

    @Test("Issuer and audience claims are enforced when configured")
    func issuerAndAudienceEnforced() async throws {
        let constrained = APIAccessTokenAuthenticationSettings(
            hs256Secret: "unit-test-secret",
            issuer: "harness-test",
            audience: "harness-api"
        )
        let owner = UUID()
        let token = try await HarnessAPIAccessTokenFactory.mint(
            ownerAccountID: owner,
            settings: constrained
        )
        let validator = JWTAPIAccessTokenValidator(settings: constrained)
        let resolved = try validator.validatedOwnerAccountID(bearerToken: token)
        #expect(resolved == owner)

        let wrongIssuer = JWTAPIAccessTokenValidator(
            settings: APIAccessTokenAuthenticationSettings(
                hs256Secret: "unit-test-secret",
                issuer: "wrong",
                audience: "harness-api"
            )
        )
        #expect(throws: APIAccessTokenValidationError.self) {
            try wrongIssuer.validatedOwnerAccountID(bearerToken: token)
        }
    }

    @Test("APILayer start fails closed when strict tenancy has no validator")
    func startFailsClosedWithoutValidator() async throws {
        let api = APILayer(port: 0)
        await api.setModelProvider(AuthTestModelProvider())
        await api.setChatGatewayServices(
            APILayerChatGatewayServices(
                conversation: ProtocolOnlyConversationGatewayStub(),
                runtime: ProtocolOnlyRuntimeGatewayStub()
            )
        )
        await api.setTenancyPolicySettings(TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true))
        await #expect(throws: APIError.authenticationNotConfigured) {
            try await api.start()
        }
        await api.stop()
    }

    @Test("ServerConfig factory builds validator and tenancy settings")
    func serverConfigWiring() {
        var config = ServerConfig(
            apiAccessTokenHS256Secret: "secret",
            requireAuthenticatedTenantOnAPI: true
        )
        #expect(config.tenancyPolicySettings().requireAuthenticatedOwnerOnMutations == true)
        #expect(config.makeAPIAccessTokenValidator() != nil)
        config.apiAccessTokenHS256Secret = ""
        #expect(config.makeAPIAccessTokenValidator() == nil)
    }
}

private final class AuthTestModelProvider: APILayerModelManaging, Sendable {
    func getAvailableModels() async -> [Model] { [] }
}
