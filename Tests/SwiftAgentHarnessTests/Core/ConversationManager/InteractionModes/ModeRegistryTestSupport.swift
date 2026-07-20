import Foundation
@testable import SwiftAgentHarness

enum ModeRegistryTestSupport {
    static func makeService(
        seedingBuiltIns: Bool = true,
        modeProfileConfiguration: ModeProfileConfiguration? = nil,
        projectConfigDirectory: URL? = nil,
        projectConfigSource: ModeProfileProjectConfigSource? = nil,
        additionalProfiles: [ResolvedModeProfile] = []
    ) -> ModeRegistryService {
        let resolvedModeProfileConfiguration = modeProfileConfiguration ?? {
            PromptConfigBundleResource.enableTestBundleFallbackForTesting()
            return HarnessConfigurationSet.resolveFromAmbient().modeProfiles
        }()
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
        let resolvedModeProfileConfiguration = modeProfileConfiguration ?? {
            PromptConfigBundleResource.enableTestBundleFallbackForTesting()
            return HarnessConfigurationSet.resolveFromAmbient().modeProfiles
        }()
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
