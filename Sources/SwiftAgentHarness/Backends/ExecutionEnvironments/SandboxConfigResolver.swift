import Foundation

public enum SandboxConfigResolver {
    public static func resolveScopeKey(scope: SandboxScope, sessionKey: String, agentID: String) -> String {
        switch scope {
        case .agent: return "agent:\(agentID)"
        case .session: return "session:\(sessionKey)"
        case .shared: return "shared"
        }
    }

    public static func resolve(
        global: SandboxGlobalSettings,
        agentID: String,
        sessionKey: String,
        isMainSession: Bool
    ) -> SandboxConfig {
        let modeActive: Bool = switch global.mode {
        case .off: false
        case .nonMain: !isMainSession
        case .all: true
        }
        let sandboxingActive = global.enabled && modeActive
        let backend: SandboxBackendID = sandboxingActive ? global.backend : "local"
        return SandboxConfig(
            mode: global.mode,
            scope: global.scope,
            backend: backend,
            sandboxingActive: sandboxingActive,
            assistantBlockingBudgetSeconds: global.assistantBlockingBudgetSeconds,
            docker: global.docker,
            ssh: global.ssh,
            openshell: global.openshell,
            browser: global.browser,
            prune: global.prune
        )
    }
}
