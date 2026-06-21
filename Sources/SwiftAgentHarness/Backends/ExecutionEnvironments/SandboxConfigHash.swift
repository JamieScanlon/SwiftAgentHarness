import CryptoKit
import Foundation

public enum SandboxConfigHash {
    public static func compute(config: SandboxConfig) -> String {
        let payload = "\(config.mode.rawValue)|\(config.scope.rawValue)|\(config.backend)|\(config.docker.image)|\(config.docker.network)|\(config.docker.pidsLimit)|\(config.docker.memoryLimit)|\(config.docker.cpus)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
