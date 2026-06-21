import Foundation

enum DockerSandboxRunArgs {
    private static let fallbackUID: UInt32 = 65534
    private static let fallbackGID: UInt32 = 65534

    static func resolveRunUser(hostWorkspace: String, fileManager: FileManager = .default) -> (uid: UInt32, gid: UInt32) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: hostWorkspace) else {
            return (fallbackUID, fallbackGID)
        }
        let uid = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? fallbackUID
        let gid = (attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? fallbackGID
        return (uid, gid)
    }

    static func build(
        containerName: String,
        settings: DockerSandboxSettings,
        hostWorkspace: String,
        runUser: (uid: UInt32, gid: UInt32),
        configHash: String
    ) -> [String] {
        [
            "docker", "run", "-d", "--name", containerName,
            "--label", "sah.configHash=\(configHash)",
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges:true",
            "--user", "\(runUser.uid):\(runUser.gid)",
            "--pids-limit", String(settings.pidsLimit),
            "--memory", settings.memoryLimit,
            "--cpus", String(settings.cpus),
            "--read-only",
            "--tmpfs", "/tmp:exec,mode=1777",
            "--tmpfs", "/run:exec,mode=755",
            "--network", settings.network,
            "-v", "\(hostWorkspace):\(settings.workdir)",
            "-w", settings.workdir,
            settings.image,
            "sleep", "infinity",
        ]
    }
}
