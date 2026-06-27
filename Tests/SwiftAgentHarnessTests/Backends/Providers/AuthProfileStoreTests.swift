import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("AuthProfileStore")
struct AuthProfileStoreTests {
    @Test("Env var resolution uses manifest-declared keys")
    func envResolution() throws {
        let store = AuthProfileStore(environment: ["OPENAI_API_KEY": "sk-test"])
        let resolved = try store.resolveAPIKey(providerID: "openai")
        #expect(resolved.apiKey == "sk-test")
        #expect(resolved.profile.source == .env)
    }

    @Test("Profile-scoped env var takes precedence")
    func profileScopedEnv() throws {
        let store = AuthProfileStore(
            environment: [
                "OPENAI_API_KEY": "sk-default",
                "OPENAI_API_KEY_WORK": "sk-work",
            ],
            defaultAuthProfileLabel: "work"
        )
        let resolved = try store.resolveAPIKey(providerID: "openai")
        #expect(resolved.apiKey == "sk-work")
    }

    @Test("auth-profiles.json overrides env")
    func fileOverridesEnv() throws {
        let fileData = """
        {
          "work": {
            "openai": { "apiKey": "sk-from-file" }
          }
        }
        """.data(using: .utf8)!
        let store = AuthProfileStore(
            environment: ["OPENAI_API_KEY": "sk-env"],
            defaultAuthProfileLabel: "work",
            authProfilesFileData: fileData
        )
        let resolved = try store.resolveAPIKey(providerID: "openai")
        #expect(resolved.apiKey == "sk-from-file")
        #expect(resolved.profile.source == .config)
    }
}

@Suite("AuthProfileCooldownState")
struct AuthProfileCooldownStateTests {
    @Test("Credential exhausted marks one hour cooldown")
    func billingCooldown() {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = AuthProfileCooldownState()
        state.mark(classification: .credentialExhausted, now: now, billingCooldown: 3600)
        #expect(state.lastStatus == .exhausted)
        #expect(state.isAvailable(at: now) == false)
        #expect(state.isAvailable(at: now.addingTimeInterval(3600)) == true)
    }

    @Test("Rate limited marks shorter cooldown")
    func rateLimitCooldown() {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = AuthProfileCooldownState()
        state.mark(classification: .rateLimited, now: now, rateLimitCooldown: 900)
        #expect(state.lastStatus == .rateLimited)
        #expect(state.isAvailable(at: now.addingTimeInterval(899)) == false)
        #expect(state.isAvailable(at: now.addingTimeInterval(900)) == true)
    }
}
