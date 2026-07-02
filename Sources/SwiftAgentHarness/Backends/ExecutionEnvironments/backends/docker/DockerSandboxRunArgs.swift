import Foundation

enum DockerSandboxRunArgs {
    private static let fallbackUID: UInt32 = 65534
    private static let fallbackGID: UInt32 = 65534

    private struct HardenedContainerSpec {
        let containerName: String
        let image: String
        let network: String
        let pidsLimit: Int
        let memoryLimit: String
        let cpus: Double
        let runUser: (uid: UInt32, gid: UInt32)
        let configHash: String
        let workdir: String?
        let hostWorkspaceBind: String?
        let extraTmpfs: [String]
    }

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
        build(spec: HardenedContainerSpec(
            containerName: containerName,
            image: settings.image,
            network: settings.network,
            pidsLimit: settings.pidsLimit,
            memoryLimit: settings.memoryLimit,
            cpus: settings.cpus,
            runUser: runUser,
            configHash: configHash,
            workdir: settings.workdir,
            hostWorkspaceBind: "\(hostWorkspace):\(settings.workdir)",
            extraTmpfs: []
        ))
    }

    static func buildBrowser(
        containerName: String,
        settings: BrowserSandboxSettings,
        runUser: (uid: UInt32, gid: UInt32),
        configHash: String,
        workdir: String = "/home/browser"
    ) -> [String] {
        build(spec: HardenedContainerSpec(
            containerName: containerName,
            image: settings.image,
            network: settings.network,
            pidsLimit: settings.pidsLimit,
            memoryLimit: settings.memoryLimit,
            cpus: settings.cpus,
            runUser: runUser,
            configHash: configHash,
            workdir: workdir,
            hostWorkspaceBind: nil,
            extraTmpfs: ["/home/browser:exec,mode=700,uid=\(runUser.uid),gid=\(runUser.gid)"]
        ))
    }

    private static func build(spec: HardenedContainerSpec) -> [String] {
        var argv: [String] = [
            "docker", "run", "-d", "--name", spec.containerName,
            "--label", "sah.configHash=\(spec.configHash)",
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges:true",
            "--user", "\(spec.runUser.uid):\(spec.runUser.gid)",
            "--pids-limit", String(spec.pidsLimit),
            "--memory", spec.memoryLimit,
            "--cpus", String(spec.cpus),
            "--read-only",
            "--tmpfs", "/tmp:exec,mode=1777",
            "--tmpfs", "/run:exec,mode=755",
        ]
        for mount in spec.extraTmpfs {
            argv.append(contentsOf: ["--tmpfs", mount])
        }
        argv.append(contentsOf: ["--network", spec.network])
        if let hostWorkspaceBind = spec.hostWorkspaceBind {
            argv.append(contentsOf: ["-v", hostWorkspaceBind])
        }
        if let workdir = spec.workdir {
            argv.append(contentsOf: ["-w", workdir])
        }
        argv.append(contentsOf: [spec.image, "sleep", "infinity"])
        return argv
    }
}
