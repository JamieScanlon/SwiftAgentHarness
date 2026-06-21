import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ModelPoolBudgetConfiguration")
struct ModelPoolBudgetConfigurationTests {
    @Test("safe defaults resolve to enabled policy with ceilings")
    func safeDefaultsPolicy() {
        let policy = ModelPoolBudgetConfiguration.safeDefaults.resolvedPolicy()
        guard case .enabled(let perCall, let perConversation, let global, let perAccount, let fallback) = policy else {
            Issue.record("expected enabled policy")
            return
        }
        #expect(perCall == 1.0)
        #expect(perConversation == 10.0)
        #expect(global == 100.0)
        #expect(perAccount == nil)
        #expect(fallback == .denyWhenUnknown)
    }

    @Test("JSON settings merge into configuration")
    func jsonSettings() {
        let settings: [String: Any] = [
            "modelPoolBudget": [
                "enabled": true,
                "maxUSDPerCall": 2.0,
                "maxUSDPerConversation": 20.0,
                "maxUSDGlobal": 200.0,
                "denyWhenUnknownProjectedCost": false,
            ],
        ]
        let config = ModelPoolBudgetConfiguration.configuration(fromSettingsJSON: settings)
        #expect(config.maxUSDPerCall == 2.0)
        #expect(config.maxUSDPerConversation == 20.0)
        #expect(config.maxUSDGlobal == 200.0)
        #expect(config.denyWhenUnknownProjectedCost == false)
        let policy = config.resolvedPolicy()
        guard case .enabled(_, _, _, _, let fallback) = policy else {
            Issue.record("expected enabled policy")
            return
        }
        #expect(fallback == .allowWhenUnknown)
    }

    @Test("ServerConfig overrides apply on top of bundle config")
    func serverConfigOverrides() {
        let base = ModelPoolBudgetConfiguration.safeDefaults
        let config = ServerConfig(modelPoolMaxUSDPerCallOverride: 0.5)
        let resolved = base.applyingOverrides(serverConfig: config)
        #expect(resolved.maxUSDPerCall == 0.5)
    }
}
