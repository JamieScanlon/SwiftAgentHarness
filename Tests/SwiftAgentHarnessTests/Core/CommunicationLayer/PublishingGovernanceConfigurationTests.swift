import Testing
@testable import SwiftAgentHarness

struct PublishingGovernanceConfigurationTests {
    @Test func defaultPolicyIsStrict() {
        let cfg = PublishingGovernanceConfiguration.defaultStrict
        #expect(cfg.mode == .strict)
        #expect(cfg.rejectsInvalidPayloads == true)
    }

    @Test func overrideCanSwitchToSoft() {
        let cfg = PublishingGovernanceConfiguration.defaultStrict
            .applyingOverrides(modeRawOverride: "soft", diagnosticsEnabledOverride: true)
        #expect(cfg.mode == .soft)
        #expect(cfg.rejectsInvalidPayloads == false)
        #expect(cfg.diagnosticsEnabled == true)
    }
}
