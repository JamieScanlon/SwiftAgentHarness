import Foundation

extension AgentRuntimeTurnConfiguration {
    init(managerConfiguration: HarnessRuntimeSession.Configuration) {
        self.init(
            enableTools: managerConfiguration.enableTools,
            enableAgents: managerConfiguration.enableAgents,
            allowEscalatedTools: managerConfiguration.allowEscalatedTools,
            preApprovedToolNames: managerConfiguration.preApprovedToolNames,
            preApprovedCallBindings: managerConfiguration.preApprovedCallBindings,
            preApprovedToolRules: managerConfiguration.preApprovedToolRules,
            expectedPreviousTailHarnessMessageID: managerConfiguration.expectedPreviousTailHarnessMessageID,
            inputTrustRaw: managerConfiguration.inputTrustRaw,
            resolvedInputTrustClass: managerConfiguration.resolvedInputTrustClass,
            ephemeralSystemReminder: managerConfiguration.ephemeralSystemReminder,
            originSurface: managerConfiguration.originSurface,
            originSenderID: managerConfiguration.originSenderID,
            originSenderIsOwner: managerConfiguration.originSenderIsOwner,
            turnThinkingOverride: managerConfiguration.turnThinkingOverride,
            turnModelSlug: managerConfiguration.turnModelSlug,
            runLaneOrigin: managerConfiguration.runLaneOrigin
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
            preApprovedCallBindings: runtimeConfiguration.preApprovedCallBindings,
            preApprovedToolRules: runtimeConfiguration.preApprovedToolRules,
            expectedPreviousTailHarnessMessageID: runtimeConfiguration.expectedPreviousTailHarnessMessageID,
            inputTrustRaw: runtimeConfiguration.inputTrustRaw,
            resolvedInputTrustClass: runtimeConfiguration.resolvedInputTrustClass,
            ephemeralSystemReminder: runtimeConfiguration.ephemeralSystemReminder,
            originSurface: runtimeConfiguration.originSurface,
            originSenderID: runtimeConfiguration.originSenderID,
            originSenderIsOwner: runtimeConfiguration.originSenderIsOwner,
            turnThinkingOverride: runtimeConfiguration.turnThinkingOverride,
            turnModelSlug: runtimeConfiguration.turnModelSlug,
            runLaneOrigin: runtimeConfiguration.runLaneOrigin
        )
    }
}
