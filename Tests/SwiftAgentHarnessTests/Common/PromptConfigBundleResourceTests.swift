import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PromptConfigBundleResource")
struct PromptConfigBundleResourceTests {
    @Test("test bundle exposes PromptConfig.json")
    func testBundleProvidesPromptConfig() {
        #expect(PromptConfigBundleResource.url() != nil)
    }

    @Test("test PromptConfig disables agent skills for orchestrator warm-up")
    func testPromptConfigDisablesAgentSkills() {
        #expect(SystemPrompt.loadIncludeAgentSkillsFromConfig() == false)
    }
}

/// Tests that mutate process-global resolver state (overrides, registered bundles, environment).
/// Serialized so the shared state is never observed concurrently, and every test restores defaults.
@Suite("PromptConfigBundleResource — host overrides", .serialized)
struct PromptConfigBundleResourceOverrideTests {
    private static let marker = "marker"

    /// Builds a *valid* PromptConfig payload carrying the round-trip marker.
    ///
    /// These tests mutate the process-global `PromptConfigBundleResource`. The suite is
    /// `.serialized`, but that only orders tests within this suite — other suites still run in
    /// parallel and may read this override (e.g. orchestrator warm-up builds a `SystemPrompt`,
    /// which reads `options.includeAgentSkills`). A payload missing `options` makes those concurrent
    /// builds fall back to skills-enabled and throw `skillLoaderNotFound`, nulling their orchestrator
    /// and flaking unrelated suites. Include valid `options`, `settings`, and `agentHarness` blocks.
    private func config(_ value: String) -> Data {
        Data("""
        {"\(Self.marker)":"\(value)","options":{"includeAgentSkills":false,"includeCurrentDateTime":true},"settings":{},"agentHarness":{"strictAgentHarnessPrompts":true}}
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
        defer { PromptConfigBundleResource.resetForTesting() }
        PromptConfigBundleResource.configure(data: config("from-data"))
        #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-data")
    }

    @Test("configure(url:) resolves both url() and data()")
    func configureURLOverride() throws {
        defer { PromptConfigBundleResource.resetForTesting() }
        let url = try writeTempConfig("from-url")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        PromptConfigBundleResource.configure(url: url)
        #expect(PromptConfigBundleResource.url() == url)
        #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-url")
    }

    @Test("environment variable path resolves config")
    func environmentOverride() throws {
        defer { PromptConfigBundleResource.resetForTesting() }
        let url = try writeTempConfig("from-env")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        setenv(PromptConfigBundleResource.environmentKey, url.path, 1)
        defer { unsetenv(PromptConfigBundleResource.environmentKey) }

        #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-env")
    }

    @Test("programmatic override beats environment variable")
    func overrideBeatsEnvironment() throws {
        defer { PromptConfigBundleResource.resetForTesting() }
        let envURL = try writeTempConfig("from-env")
        defer { try? FileManager.default.removeItem(at: envURL.deletingLastPathComponent()) }

        setenv(PromptConfigBundleResource.environmentKey, envURL.path, 1)
        defer { unsetenv(PromptConfigBundleResource.environmentKey) }

        PromptConfigBundleResource.configure(data: config("from-override"))
        #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-override")
    }

    @Test("registered bundle is searched ahead of the default fallback")
    func registeredBundleOverride() throws {
        defer { PromptConfigBundleResource.resetForTesting() }
        let url = try writeTempConfig("from-registered")
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try #require(Bundle(url: dir))
        PromptConfigBundleResource.registerBundle(bundle)
        #expect(markerValue(of: PromptConfigBundleResource.data()) == "from-registered")
    }

    @Test("resetForTesting restores default bundle resolution")
    func resetRestoresDefault() {
        PromptConfigBundleResource.configure(data: config("temporary"))
        PromptConfigBundleResource.resetForTesting()
        #expect(PromptConfigBundleResource.url() != nil)
        #expect(markerValue(of: PromptConfigBundleResource.data()) != "temporary")
    }
}
