import Foundation

struct SandboxToolExecutionEnvironmentAdapter: ToolExecutionEnvironmentAdapting {
    let id = "tool-execution-environment.sandbox"

    func descriptor(for entry: ToolRegistryEntry) -> ToolRegistryEntry.ExecutionEnvironmentDescriptor {
        let base = entry.executionEnvironment
        if let manifest = SandboxBackendManifests.manifest(forAdapterID: base.adapterID)
            ?? SandboxBackendManifests.manifest(for: backendID(from: base.adapterID)) {
            let kind: ToolRegistryEntry.ExecutionEnvironmentKind = switch manifest.id {
            case "local", "docker-browser": .local
            case "docker": .docker
            case "ssh": .ssh
            case "openshell": .docker
            default: .unknown
            }
            let isolation: ToolRegistryEntry.ExecutionIsolationLevel = manifest.capabilities.persistentRuntime
                ? .remoteManaged
                : .inProcess
            return ToolRegistryEntry.ExecutionEnvironmentDescriptor(
                kind: kind,
                adapterID: manifest.adapterID,
                isolationLevel: isolation
            )
        }
        return base
    }

    private func backendID(from adapterID: String) -> String {
        if adapterID.hasPrefix("tool-env."), adapterID.hasSuffix(".default") {
            let trimmed = adapterID.dropFirst("tool-env.".count).dropLast(".default".count)
            return String(trimmed)
        }
        return adapterID
    }
}
