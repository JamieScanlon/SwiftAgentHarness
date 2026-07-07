import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("Provider open-set auth", .serialized)
struct ProviderOpenAuthTests {
    @Test("spec OAuth choice validates with empty envVars")
    func specOAuthChoiceValidates() throws {
        let manifest = ProviderManifest(
            id: "oauth-provider",
            label: "OAuth Provider",
            providerEndpoints: [
                ProviderEndpoint(id: "default", baseURL: URL(string: "https://oauth.example/v1")!),
            ],
            providerAuthChoices: [
                ProviderAuthChoice(
                    id: "oauth",
                    label: "Sign in",
                    envVars: [],
                    onboardingScopes: ["openid", "profile", "offline_access"]
                ),
            ],
            modelSupport: ProviderModelSupport(modelPrefixes: ["model-"])
        )
        try ProviderManifestValidation.validate(manifest)
        #expect(manifest.providerAuthChoices[0].resolvedAuthType == .oauth)
    }

    @Test("api-key choice still requires envVars")
    func apiKeyChoiceRequiresEnvVars() {
        let manifest = ProviderManifest(
            id: "key-provider",
            label: "Key Provider",
            providerEndpoints: [
                ProviderEndpoint(id: "default", baseURL: URL(string: "https://key.example/v1")!),
            ],
            providerAuthChoices: [
                ProviderAuthChoice(id: "api-key", label: "API Key", envVars: []),
            ],
            modelSupport: ProviderModelSupport(modelPrefixes: [])
        )
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderManifestValidation.validate(manifest)
        }
    }

    @Test("oauth choice id infers oauth auth type")
    func oauthChoiceInference() {
        let choice = ProviderAuthChoice(
            id: "oauth",
            label: "Sign in",
            envVars: [],
            onboardingScopes: ["openid"]
        )
        #expect(choice.resolvedAuthType == .oauth)
    }

    @Test("config oauth profile round-trips through credential pool")
    func configOAuthProfileRoundTrip() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let fileData = """
        {
          "default": {
            "openai": {
              "authType": "oauth",
              "accessToken": "access-abc",
              "refreshToken": "refresh-xyz",
              "expiresAt": 4102444800,
              "priority": 0
            }
          }
        }
        """.data(using: .utf8)!
        let store = AuthProfileStore(authProfilesFileData: fileData)
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.count == 1)
        #expect(pool[0].authType == .oauth)
        #expect(pool[0].refreshToken == "refresh-xyz")
        #expect(pool[0].source == .oauthStore)
        let resolved = try store.resolveCredential(providerID: "openai")
        #expect(resolved.bearerToken == "access-abc")
    }

    @Test("expired access token is excluded from dispatch resolution")
    func expiredAccessTokenExcluded() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let fileData = """
        {
          "default": {
            "openai": {
              "authType": "oauth",
              "accessToken": "expired-access",
              "refreshToken": "refresh-xyz",
              "expiresAt": 1
            }
          }
        }
        """.data(using: .utf8)!
        let store = AuthProfileStore(authProfilesFileData: fileData)
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.count == 1)
        #expect(pool[0].requiresOnboarding)
        #expect(throws: AuthProfileStoreError.self) {
            _ = try store.resolveCredential(providerID: "openai")
        }
    }

    @Test("refresh-only oauth requires onboarding on resolveCredential")
    func refreshOnlyRequiresOnboarding() throws {
        ProviderTestManifestSupport.prepareRegistry()
        let fileData = """
        {
          "default": {
            "openai": {
              "authType": "oauth",
              "refreshToken": "refresh-only"
            }
          }
        }
        """.data(using: .utf8)!
        let store = AuthProfileStore(authProfilesFileData: fileData)
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.count == 1)
        #expect(throws: AuthProfileStoreError.self) {
            _ = try store.resolveCredential(providerID: "openai")
        }
    }

    @Test("missing api key returns MissingAuthCredentialLLM from factory")
    func missingKeyUsesMissingAuthLLM() async throws {
        ProviderTestManifestSupport.prepareRegistry()
        let store = AuthProfileStore(environment: [:])
        let binding = ProviderBinding(
            providerId: "openai",
            modelProtocol: .openAIAPI,
            endpointModelId: "gpt-4o",
            serverURL: URL(string: "https://api.openai.com/v1")!
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "gpt-4o",
            serverURL: URL(string: "https://api.openai.com/v1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let llm = StandardModelLLMFactory.makeBindingAdapter(
            binding: binding,
            model: model,
            systemPrompt: prompt,
            logger: nil,
            authProfileStore: store
        )
        #expect(llm is MissingAuthCredentialLLM)
    }

    @Test("NoOpOAuthTokenRefresher throws refreshNotImplemented")
    func noOpRefresherThrows() async {
        let profile = AuthProfile(
            id: "oauth-1",
            providerID: "openai",
            authType: .oauth,
            refreshToken: "refresh"
        )
        let refresher = NoOpOAuthTokenRefresher()
        await #expect(throws: AuthProfileStoreError.self) {
            _ = try await refresher.refreshAccessToken(profile: profile, scopes: ["openid"])
        }
    }
}
