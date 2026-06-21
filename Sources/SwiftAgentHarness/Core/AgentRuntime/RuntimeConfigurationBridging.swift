import Foundation

extension AgentRuntimeTurnConfiguration {
    init(managerConfiguration: HarnessRuntimeSession.Configuration) {
        self.init(
            enableTools: managerConfiguration.enableTools,
            enableAgents: managerConfiguration.enableAgents,
            allowEscalatedTools: managerConfiguration.allowEscalatedTools,
            preApprovedToolNames: managerConfiguration.preApprovedToolNames,
            expectedPreviousTailHarnessMessageID: managerConfiguration.expectedPreviousTailHarnessMessageID,
            inputTrustRaw: managerConfiguration.inputTrustRaw,
            resolvedInputTrustClass: managerConfiguration.resolvedInputTrustClass,
            ephemeralSystemReminder: managerConfiguration.ephemeralSystemReminder,
            originSurface: managerConfiguration.originSurface,
            originSenderID: managerConfiguration.originSenderID
        )
    }
}

extension HarnessRuntimeSession.Configuration {
    init(runtimeConfiguration: AgentRuntimeTurnConfiguration) {
        self.init(
            enableTools: runtimeConfiguration.enableTools,
            enableAgents: runtimeConfiguration.enableAgents,
            allowEscalatedTools: runtimeConfiguration.allowEscalatedTools,
            preApprovedToolNames: runtimeConfiguration.preApprovedToolNames,
            expectedPreviousTailHarnessMessageID: runtimeConfiguration.expectedPreviousTailHarnessMessageID,
            inputTrustRaw: runtimeConfiguration.inputTrustRaw,
            resolvedInputTrustClass: runtimeConfiguration.resolvedInputTrustClass,
            ephemeralSystemReminder: runtimeConfiguration.ephemeralSystemReminder,
            originSurface: runtimeConfiguration.originSurface,
            originSenderID: runtimeConfiguration.originSenderID
        )
    }
}
