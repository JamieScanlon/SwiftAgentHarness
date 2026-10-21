import Foundation
@testable import SwiftAgentHarness

enum ModeRegistryTestSupport {
    /// Mode profiles from the test target's `PromptConfig.json`, read straight from `Bundle.module`
    /// so they never depend on `PromptConfigBundleResource` state that other tests mutate.
    static let testPromptConfigModeProfiles: ModeProfileConfiguration = {
        guard let url = Bundle.module.url(forResource: "PromptConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? PromptConfigDocument.parse(data: data) else {
            preconditionFailure("Test target PromptConfig.json is missing or unparseable")
        }
        return ModeProfileConfiguration.load(from: document)
    }()

    static func makeService(
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        projectConfigDirectory: URL? = nil,
        projectConfigSource: ModeProfileProjectConfigSource? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) -> ModeRegistryService {
        let resolvedModeProfileConfiguration = modeProfileConfiguration ?? testPromptConfigModeProfiles
        return ModeRegistryService(
            seedingBuiltIns: seedingBuiltIns,
            modeProfileConfiguration: resolvedModeProfileConfiguration,
            projectConfigDirectory: projectConfigDirectory,
            projectConfigSource: projectConfigSource,
            additionalProfiles: additionalProfiles
        )
    }

    static func makePort(
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        projectConfigDirectory: URL? = nil,
        projectConfigSource: ModeProfileProjectConfigSource? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) -> ModeRegistryPortAdapter {
        let resolvedModeProfileConfiguration = modeProfileConfiguration ?? testPromptConfigModeProfiles
        return ModeRegistryPortAdapter(
            service: makeService(
                seedingBuiltIns: seedingBuiltIns,
                modeProfileConfiguration: resolvedModeProfileConfiguration,
                projectConfigDirectory: projectConfigDirectory,
                projectConfigSource: projectConfigSource,
                additionalProfiles: additionalProfiles
            )
        )
    }
}
