import Foundation

public enum MemoryCLI {
    public static func run(arguments: [String]) -> Never? {
        guard arguments.count >= 2, arguments[1] == "memory" else { return nil }
        let sub = arguments.count >= 3 ? arguments[2] : "list"
        let cwd = ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
        let service = DefaultMemoryService()
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
            default:
                fputs("usage: memory list|show|remove\n", stderr)
                exit(1)
            }
        } catch {
            fputs("memory error: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }
}
