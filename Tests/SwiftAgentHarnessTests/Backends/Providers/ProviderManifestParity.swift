import Foundation
@testable import SwiftAgentHarness

/// Normalizes manifests for bundled JSON ↔ static Swift catalog parity checks.
enum ProviderManifestParity {
    /// Canonicalizes local-provider endpoint URLs so bundled JSON (fixed localhost)
    /// compares equal to runtime manifests sourced from ``Constants``.
    static func normalize(_ manifest: ProviderManifest) -> ProviderManifest {
        var normalized = manifest
        normalized.providerEndpoints = manifest.providerEndpoints.map { endpoint in
            var copy = endpoint
            switch manifest.id {
            case "ollama":
                copy.baseURL = URL(string: "http://localhost:11434")!
            case "lmstudio":
                copy.baseURL = URL(string: "http://localhost:1234")!
            default:
                break
            }
            return copy
        }
        return normalized
    }
}
