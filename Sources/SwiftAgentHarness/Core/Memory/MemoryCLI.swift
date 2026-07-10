import Foundation

public enum MemoryCLI {
    public static func run(arguments: [String]) -> Never? {
        guard arguments.count >= 2, arguments[1] == "memory" else { return nil }
        let sub = arguments.count >= 3 ? arguments[2] : "list"
        let cwd = ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
        let config = MemoryConfigurationLoader.loadFromPromptConfigBundle()
        let service = DefaultMemoryService(config: config)
        do {
            let context = try service.makeSessionContext(conversationID: UUID(), cwd: cwd)
            let store = AgentMemoryStore(memoryDirectory: context.memoryDirectory)
            try store.ensureLayout()
            switch sub {
            case "list":
                for entry in store.manifest() {
                    print("\(entry.filename)\t[\(entry.memoryType.rawValue)]\t\(entry.description)")
                }
            case "show":
                let name = arguments.count >= 4 ? arguments[3] : "MEMORY.md"
                if let body = try store.readTopicBody(filename: name) {
                    print(body)
                } else {
                    let index = try String(contentsOf: store.indexURL, encoding: .utf8)
                    print(index)
                }
            case "remove":
                guard arguments.count >= 4 else {
                    fputs("usage: memory remove <filename>\n", stderr)
                    exit(1)
                }
                let path = try WorkspacePathPolicy.resolveMemoryRelativePath(
                    raw: arguments[3],
                    memoryDirectory: context.memoryDirectory,
                    requireExists: true
                )
                try FileManager.default.removeItem(atPath: path)
                print("removed \(arguments[3])")
            case "rem-backfill":
                let flags = Set(arguments.dropFirst(3))
                let wantsRollback = flags.contains("--rollback") || flags.contains("--rollback-short-term")
                guard wantsRollback else {
                    fputs("usage: memory rem-backfill --rollback|--rollback-short-term\n", stderr)
                    exit(1)
                }
                try DreamingConsolidationScheduler.rollbackLastPromotionRun(
                    memoryDirectory: context.memoryDirectory
                )
                print("rolled back last dreaming promotion run")
            case "dreaming":
                let action = arguments.count >= 4 ? arguments[3].lowercased() : "status"
                switch action {
                case "status":
                    let summary = DreamingControlStore().statusSummary(
                        cronExpr: config.dreamingCron,
                        memoryDirectory: context.memoryDirectory,
                        config: config
                    )
                    print(summary)
                case "explain":
                    let report = try DreamSweepReportStore(memoryDirectory: context.memoryDirectory).read()
                    print(DreamingReviewFormatter.explain(
                        report: report,
                        memoryDirectory: context.memoryDirectory
                    ))
                default:
                    fputs("usage: memory dreaming status|explain\n", stderr)
                    exit(1)
                }
            case "active-memory":
                let action = arguments.count >= 4 ? arguments[3].lowercased() : "status"
                guard action == "status" else {
                    fputs("usage: memory active-memory status\n", stderr)
                    exit(1)
                }
                print(ActiveMemoryControlStore().statusSummary(config: config))
            case "status":
                let deep = arguments.contains("--deep")
                let errorBox = StatusErrorBox()
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    defer { semaphore.signal() }
                    do {
                        try await printStatus(service: service, context: context, deep: deep)
                    } catch {
                        errorBox.error = error
                    }
                }
                semaphore.wait()
                if let statusError = errorBox.error {
                    fputs("memory status error: \(statusError)\n", stderr)
                    exit(1)
                }
                exit(0)
            default:
                fputs("usage: memory list|show|remove|rem-backfill --rollback|dreaming status|explain|active-memory status|status [--deep]\n", stderr)
                exit(1)
            }
        } catch {
            fputs("memory error: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    private final class StatusErrorBox: @unchecked Sendable {
        var error: Error?
    }

    private static func printStatus(
        service: DefaultMemoryService,
        context: MemorySessionContext,
        deep: Bool
    ) async throws {
        let pluginID = await service.activeMemoryPluginID()
        print("active-memory-plugin: \(pluginID)")
        if deep {
            _ = try await service.bootstrapSession(context: context)
            let artifacts = await service.activePublicArtifacts(conversationID: context.conversationID)
            print("public-artifacts: \(artifacts.count)")
            for artifact in artifacts {
                print("\(artifact.kind)\t\(artifact.relativePath)\t\(artifact.absolutePath)")
            }
        }
    }
}
