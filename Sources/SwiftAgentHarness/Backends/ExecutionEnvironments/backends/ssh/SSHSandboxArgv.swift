import Foundation

enum SSHSandboxArgv {
    static func destination(_ settings: SSHSandboxSettings) -> String {
        "\(settings.user)@\(settings.host)"
    }

    static func base(control: SSHControlMaster, settings: SSHSandboxSettings, usePty: Bool = false) -> [String] {
        var argv = control.baseArgs
        if usePty { argv.insert("-tt", at: 1) }
        if let identity = settings.identityFile {
            argv.insert(contentsOf: ["-i", identity], at: 1)
        }
        return argv
    }

    static func exec(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        remoteCommand: String,
        usePty: Bool = false
    ) -> [String] {
        base(control: control, settings: settings, usePty: usePty) + [destination(settings), remoteCommand]
    }

    static func rsyncTransport(control: SSHControlMaster, settings: SSHSandboxSettings) -> String {
        base(control: control, settings: settings).joined(separator: " ")
    }
}
