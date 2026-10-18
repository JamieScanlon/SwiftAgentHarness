import CryptoKit
import Foundation
import Testing
import Vapor
@testable import SwiftAgentHarness

@Suite("API access token authentication")
struct APIAccessTokenAuthenticationTests {
    private static let settings = APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.primary)

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
            settings: APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.other)
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
            hs256Secret: APIAccessTokenTestSecrets.primary,
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
                hs256Secret: APIAccessTokenTestSecrets.primary,
                issuer: "wrong",
                audience: "harness-api"
            )
        )
        #expect(throws: APIAccessTokenValidationError.self) {
            try wrongIssuer.validatedOwnerAccountID(bearerToken: token)
        }
    }

    @Test("Startup validation fails closed when strict tenancy has no validator")
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
            try await api.validateStartupPreconditions()
        }
    }

    @Test("ServerConfig factory builds validator and tenancy settings")
    func serverConfigWiring() {
        var config = ServerConfig(
            apiAccessTokenHS256Secret: APIAccessTokenTestSecrets.primary,
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

enum APIAccessTokenTestSecrets {
    static let primary = "unit-test-hs256-secret-0123456789abcdef"
    static let other = "other-hs256-secret-0123456789abcdefghij"
    /// One byte short of the RFC 7518 §3.2 minimum for HS256.
    static let tooShort = String(repeating: "s", count: APIAccessTokenAuthenticationSettings.minimumHS256SecretByteCount - 1)
}

@Suite("API access token secret strength")
struct APIAccessTokenSecretStrengthTests {
    /// Hand-signs an HS256 JWT so a short key can be exercised without going through JWTKit.
    private func handSignedToken(owner: UUID, secret: String) throws -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let exp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let payload = base64URL(Data(#"{"sub":"\#(owner.uuidString)","exp":\#(exp)}"#.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(header).\(payload)".utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return "\(header).\(payload).\(base64URL(Data(mac)))"
    }

    private func makeStartableAPILayer() async -> APILayer {
        let api = APILayer(port: 0)
        await api.setModelProvider(AuthTestModelProvider())
        await api.setChatGatewayServices(
            APILayerChatGatewayServices(
                conversation: ProtocolOnlyConversationGatewayStub(),
                runtime: ProtocolOnlyRuntimeGatewayStub()
            )
        )
        return api
    }

    @Test("Minimum length is measured in UTF-8 bytes at 32")
    func minimumLengthBoundary() {
        #expect(APIAccessTokenAuthenticationSettings.minimumHS256SecretByteCount == 32)
        #expect(!APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.tooShort).meetsMinimumHS256SecretLength)
        #expect(APIAccessTokenAuthenticationSettings(hs256Secret: String(repeating: "s", count: 32)).meetsMinimumHS256SecretLength)
        // 16 two-byte scalars = 32 UTF-8 bytes.
        #expect(APIAccessTokenAuthenticationSettings(hs256Secret: String(repeating: "é", count: 16)).meetsMinimumHS256SecretLength)
        #expect(APIAccessTokenTestSecrets.primary.utf8.count >= 32)
        #expect(APIAccessTokenTestSecrets.other.utf8.count >= 32)
    }

    @Test("Validator with a short secret rejects even a correctly signed token")
    func shortSecretValidatorFailsClosed() throws {
        let owner = UUID()
        let token = try handSignedToken(owner: owner, secret: APIAccessTokenTestSecrets.tooShort)
        let validator = JWTAPIAccessTokenValidator(
            settings: APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.tooShort)
        )
        #expect(throws: APIAccessTokenValidationError.validatorNotConfigured) {
            try validator.validatedOwnerAccountID(bearerToken: token)
        }
    }

    @Test("Hand-signed token with a strong secret validates")
    func handSignedStrongSecretValidates() throws {
        let owner = UUID()
        let token = try handSignedToken(owner: owner, secret: APIAccessTokenTestSecrets.primary)
        let validator = JWTAPIAccessTokenValidator(
            settings: APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.primary)
        )
        #expect(try validator.validatedOwnerAccountID(bearerToken: token) == owner)
    }

    @Test("Minting with a short secret throws instead of signing")
    func mintRejectsShortSecret() async {
        await #expect(throws: APIAccessTokenValidationError.validatorNotConfigured) {
            try await HarnessAPIAccessTokenFactory.mint(
                ownerAccountID: UUID(),
                settings: APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.tooShort)
            )
        }
    }

    @Test("Startup fails when a short access-token secret is configured, even without strict tenancy")
    func startupRejectsShortSecret() async throws {
        let api = await makeStartableAPILayer()
        await api.setAPIAccessTokenAuthenticationSettings(
            APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.tooShort)
        )
        await #expect(throws: APIError.accessTokenSecretTooShort(minimumBytes: 32)) {
            try await api.validateStartupPreconditions()
        }

        await api.setAPIAccessTokenAuthenticationSettings(
            APIAccessTokenAuthenticationSettings(hs256Secret: APIAccessTokenTestSecrets.primary)
        )
        try await api.validateStartupPreconditions()
    }

    @Test("Startup fails when ServerConfig supplies a short access-token secret")
    func startupRejectsShortServerConfigSecret() async throws {
        let api = await makeStartableAPILayer()
        await api.applyServerConfig(
            ServerConfig(
                apiAccessTokenHS256Secret: APIAccessTokenTestSecrets.tooShort,
                requireAuthenticatedTenantOnAPI: true
            )
        )
        await #expect(throws: APIError.accessTokenSecretTooShort(minimumBytes: 32)) {
            try await api.validateStartupPreconditions()
        }

        await api.applyServerConfig(
            ServerConfig(
                apiAccessTokenHS256Secret: APIAccessTokenTestSecrets.primary,
                requireAuthenticatedTenantOnAPI: true
            )
        )
        try await api.validateStartupPreconditions()
    }
}
