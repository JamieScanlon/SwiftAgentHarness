import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PromptConfigBundleResource")
struct PromptConfigBundleResourceTests {
    @Test("test bundle fallback is opt-in")
    func testBundleFallbackIsOptIn() {
        PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.resetForTesting()
            #expect(PromptConfigBundleResource.url() == nil)

            PromptConfigBundleResource.enableTestBundleFallbackForTesting()
            #expect(PromptConfigBundleResource.url() != nil)
        }
    }

    @Test("test bundle exposes PromptConfig.json")
    func testBundleProvidesPromptConfig() {
        PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.enableTestBundleFallbackForTesting()
            #expect(PromptConfigBundleResource.url() != nil)
        }
    }

    @Test("test PromptConfig disables agent skills for orchestrator warm-up")
    func testPromptConfigDisablesAgentSkills() {
        PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.enableTestBundleFallbackForTesting()
            let configuration = HarnessConfigurationSet.resolveFromAmbient()
            #expect(configuration.promptAssembly.includeAgentSkills == false)
        }
    }
}

/// Each test runs in ``PromptConfigBundleResource/withIsolatedStateForTesting(_:)`` so overrides,
/// registered bundles, and the environment path never leak into concurrently running suites.
@Suite("PromptConfigBundleResource — host overrides")
struct PromptConfigBundleResourceOverrideTests {
    private static let marker = "marker"

    private func config(_ value: String) -> Data {
        Data("""
        {"\(Self.marker)":"\(value)","options":{"includeAgentSkills":false,"includeCurrentDateTime":true},"settings":{},"agentHarness":{"strictAgentHarnessPrompts":true},"modeProfiles":{"profiles":[{"id":"chat","interactionMode":"chat","assemblyKind":"chat"}]}}
        """.utf8)
    }

    private func markerValue(of data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json[Self.marker] as? String
    }

    private func writeTempConfig(_ value: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-promptconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("PromptConfig.json")
        try config(value).write(to: url)
        return url
    }

    @Test("configure(data:) is honored by data()")
    func configureDataOverride() {
        PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.configure(data: config("from-data"))
            #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-data")
        }
    }

    @Test("configure(url:) resolves both url() and data()")
    func configureURLOverride() throws {
        try PromptConfigBundleResource.withIsolatedStateForTesting {
            let url = try writeTempConfig("from-url")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            PromptConfigBundleResource.configure(url: url)
            #expect(PromptConfigBundleResource.url() == url)
            #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-url")
        }
    }

    @Test("environment variable path resolves config")
    func environmentOverride() throws {
        try PromptConfigBundleResource.withIsolatedStateForTesting {
            let url = try writeTempConfig("from-env")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            PromptConfigBundleResource.setEnvironmentPathForTesting(url.path)

            #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-env")
        }
    }

    @Test("programmatic override beats environment variable")
    func overrideBeatsEnvironment() throws {
        try PromptConfigBundleResource.withIsolatedStateForTesting {
            let envURL = try writeTempConfig("from-env")
            defer { try? FileManager.default.removeItem(at: envURL.deletingLastPathComponent()) }

            PromptConfigBundleResource.setEnvironmentPathForTesting(envURL.path)

            PromptConfigBundleResource.configure(data: config("from-override"))
            #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-override")
        }
    }

    @Test("registered bundle is searched ahead of the default fallback")
    func registeredBundleOverride() throws {
        try PromptConfigBundleResource.withIsolatedStateForTesting {
            let url = try writeTempConfig("from-registered")
            let dir = url.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: dir) }

            let bundle = try #require(Bundle(url: dir))
            PromptConfigBundleResource.registerBundle(bundle)
            #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-registered")
        }
    }

    @Test("resetForTesting restores default bundle resolution")
    func resetRestoresDefault() {
        PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.configure(data: config("temporary"))
            PromptConfigBundleResource.resetForTesting()
            PromptConfigBundleResource.enableTestBundleFallbackForTesting()
            #expect(PromptConfigBundleResource.url() != nil)
            #expect(markerValue(of: PromptConfigBundleResource.data()) != "temporary")
        }
    }

    @Test("resolveFromAmbient after configure(data:) equals load(from:)")
    func resolveFromAmbientMatchesLoad() throws {
        try PromptConfigBundleResource.withIsolatedStateForTesting {
            let json = """
            {
              "options": { "includeAgentSkills": false, "includeCurrentDateTime": false },
              "agentHarness": { "strictAgentHarnessPrompts": false },
              "memory": { "activeMemoryEnabled": false }
            }
            """
            let data = Data(json.utf8)
            PromptConfigBundleResource.configure(data: data)
            let document = try PromptConfigDocument.parse(data: data)
            let fromDocument = HarnessConfigurationSet.load(from: document)
            let fromAmbient = HarnessConfigurationSet.resolveFromAmbient()

            #expect(fromAmbient.agentHarness.strictAgentHarnessPrompts == fromDocument.agentHarness.strictAgentHarnessPrompts)
            #expect(fromAmbient.promptAssembly.includeAgentSkills == fromDocument.promptAssembly.includeAgentSkills)
            #expect(fromAmbient.memory.activeMemoryEnabled == fromDocument.memory.activeMemoryEnabled)
            #expect(fromAmbient.agentHarness.strictAgentHarnessPrompts == false)
            #expect(fromAmbient.promptAssembly.includeAgentSkills == false)
        }
    }

    @Test("resolveFromAmbient with invalid config returns baseline")
    func resolveFromAmbientInvalidReturnsBaseline() {
        PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.configure(data: Data("[1]".utf8))
            let set = HarnessConfigurationSet.resolveFromAmbient()
            #expect(set.promptAssembly.includeAgentSkills == HarnessConfigurationSet.lockedDownBaseline.promptAssembly.includeAgentSkills)
            #expect(set.agentHarness.strictAgentHarnessPrompts == HarnessConfigurationSet.lockedDownBaseline.agentHarness.strictAgentHarnessPrompts)
        }
    }

    @Test("isolated state is inherited by child tasks and fresh in a nested scope")
    func isolatedStateScoping() async {
        await PromptConfigBundleResource.withIsolatedStateForTesting {
            PromptConfigBundleResource.configure(data: config("scoped"))

            async let fromChild = PromptConfigBundleResource.data()
            #expect(markerValue(of: await fromChild) == "scoped")

            let fromNested = PromptConfigBundleResource.withIsolatedStateForTesting {
                PromptConfigBundleResource.data()
            }
            #expect(fromNested == nil)
            #expect(markerValue(of: PromptConfigBundleResource.data()) == "scoped")
        }
    }
}
