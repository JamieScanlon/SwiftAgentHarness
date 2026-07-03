import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("AuthProfileStore", .serialized)
struct AuthProfileStoreTests {
    private func prepare() {
        ProviderTestManifestSupport.prepareRegistry()
    }

    @Test("Env var resolution uses manifest-declared keys")
    func envResolution() throws {
        prepare()
        let store = AuthProfileStore(environment: ["OPENAI_API_KEY": "sk-test"])
        let resolved = try store.resolveAPIKey(providerID: "openai")
        #expect(resolved.apiKey == "sk-test")
        #expect(resolved.profile.source == .env)
    }

    @Test("Profile-scoped env var takes precedence")
    func profileScopedEnv() throws {
        prepare()
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

    @Test("Explicit auth profile label resolves profile-scoped env var")
    func explicitProfileLabelEnv() throws {
        prepare()
        let store = AuthProfileStore(
            environment: [
                "SAH_OPENAI_API_KEY_PROD_WEST": "profile-key",
                "OPENAI_API_KEY": "global-key",
            ]
        )
        let resolved = try store.resolveAPIKey(
            providerID: "openai",
            authProfileLabel: "prod-west"
        )
        #expect(resolved.apiKey == "profile-key")
    }

    @Test("Default auth profile resolves team-scoped env var")
    func defaultProfileTeamScopedEnv() throws {
        prepare()
        let store = AuthProfileStore(
            environment: [
                "OPENAI_API_KEY_TEAM_A": "team-key",
                "OPENAI_API_KEY": "global-key",
            ],
            defaultAuthProfileLabel: "team-a"
        )
        let resolved = try store.resolveAPIKey(providerID: "openai")
        #expect(resolved.apiKey == "team-key")
    }

    @Test("Config file entry ranks before env in credential pool")
    func fileOverridesEnv() throws {
        prepare()
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
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.count == 2)
    }

    @Test("Numbered env vars populate ordered pool")
    func numberedEnvPool() throws {
        prepare()
        let store = AuthProfileStore(
            environment: [
                "OPENAI_API_KEY": "sk-0",
                "OPENAI_API_KEY_1": "sk-1",
                "OPENAI_API_KEY_2": "sk-2",
            ]
        )
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.map(\.apiKey) == ["sk-0", "sk-1", "sk-2"])
        #expect(pool.map(\.priority) == [0, 1, 2])
    }

    @Test("Delimited env var expands into pool entries")
    func delimitedEnvPool() throws {
        prepare()
        let store = AuthProfileStore(
            environment: ["OPENAI_API_KEYS": "sk-a,sk-b\nsk-c"]
        )
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.map(\.apiKey) == ["sk-a", "sk-b", "sk-c"])
    }

    @Test("Config keys array preserves explicit priority and id")
    func configKeysArray() throws {
        prepare()
        let fileData = """
        {
          "default": {
            "openai": {
              "keys": [
                { "id": "primary", "apiKey": "sk-primary", "priority": 0 },
                { "id": "secondary", "apiKey": "sk-secondary", "priority": 5 }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let store = AuthProfileStore(authProfilesFileData: fileData)
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.map(\.id) == ["primary", "secondary"])
        #expect(pool.map(\.priority) == [0, 5])
    }

    @Test("Duplicate secrets dedupe preferring config metadata")
    func dedupePrefersConfig() throws {
        prepare()
        let fileData = """
        {
          "default": {
            "openai": {
              "keys": [
                { "id": "from-config", "apiKey": "sk-shared", "priority": 0 }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let store = AuthProfileStore(
            environment: ["OPENAI_API_KEY": "sk-shared"],
            authProfilesFileData: fileData
        )
        let pool = try store.resolveCredentialPool(providerID: "openai")
        #expect(pool.count == 1)
        #expect(pool[0].id == "from-config")
        #expect(pool[0].source == .config)
    }

    @Test("Empty pool throws credentialNotFound")
    func emptyPoolThrows() {
        prepare()
        let store = AuthProfileStore(environment: [:])
        #expect(throws: AuthProfileStoreError.self) {
            _ = try store.resolveCredentialPool(providerID: "openai")
        }
    }
}

@Suite("AuthProfileSelector")
struct AuthProfileSelectorTests {
    @Test("Fill first skips cooled-down credentials")
    func fillFirstSkipsCooldown() {
        let pool = [
            AuthProfile(id: "a", providerID: "openai", authType: .apiKey, apiKey: "1", priority: 0),
            AuthProfile(id: "b", providerID: "openai", authType: .apiKey, apiKey: "2", priority: 1),
        ]
        let now = Date(timeIntervalSince1970: 1_000)
        var cooled = AuthProfileCooldownState()
        cooled.mark(classification: .credentialExhausted, now: now, billingCooldown: 3600)
        let result = AuthProfileSelector.selectNext(
            AuthProfileSelector.SelectionInput(
                pool: pool,
                cooldownStates: ["a": cooled],
                strategy: .fillFirst,
                now: now
            )
        )
        #expect(result?.credential.id == "b")
    }

    @Test("Round robin advances cursor")
    func roundRobinCursor() {
        let pool = [
            AuthProfile(id: "a", providerID: "openai", authType: .apiKey, apiKey: "1", priority: 0),
            AuthProfile(id: "b", providerID: "openai", authType: .apiKey, apiKey: "2", priority: 1),
        ]
        let first = AuthProfileSelector.selectNext(
            AuthProfileSelector.SelectionInput(pool: pool, strategy: .roundRobin, roundRobinCursor: 0)
        )
        let second = AuthProfileSelector.selectNext(
            AuthProfileSelector.SelectionInput(
                pool: pool,
                strategy: .roundRobin,
                roundRobinCursor: first?.nextRoundRobinCursor ?? 0
            )
        )
        #expect(first?.credential.id == "a")
        #expect(second?.credential.id == "b")
    }

    @Test("Least used prefers lowest usage count")
    func leastUsed() {
        let pool = [
            AuthProfile(id: "a", providerID: "openai", authType: .apiKey, apiKey: "1", priority: 0),
            AuthProfile(id: "b", providerID: "openai", authType: .apiKey, apiKey: "2", priority: 0),
        ]
        let result = AuthProfileSelector.selectNext(
            AuthProfileSelector.SelectionInput(
                pool: pool,
                strategy: .leastUsed,
                usageCounts: ["a": 3, "b": 1]
            )
        )
        #expect(result?.credential.id == "b")
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
