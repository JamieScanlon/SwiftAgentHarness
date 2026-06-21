import Foundation

public enum ConversationPruneCLI {
    public static func run(arguments: [String]) -> Never? {
        guard arguments.count >= 2, arguments[1] == "prune" else { return nil }
        let modeProfileID = arguments.count >= 3 ? arguments[2] : ""
        guard SubAgentModeProfileConversationPruner.supportedModeProfileIDs.contains(modeProfileID) else {
            printUsage()
            exit(1)
        }
        let execute = arguments.contains("--execute")
        guard let root = SessionPersistenceConfiguration.sessionStoreRoot else {
            fputs("prune error: SAH_SESSION_STORE_ROOT is not set\n", stderr)
            exit(1)
        }
        do {
            let persistence = try LocalHarnessSessionPersistence(
                root: root,
                agentId: SessionPersistenceConfiguration.sessionAgentId
            )
            let report = try SubAgentModeProfileConversationPruner.prune(
                using: persistence,
                modeProfileID: modeProfileID,
                execute: execute
            )
            let totalBytes = report.candidates.reduce(Int64(0)) { $0 + $1.transcriptBytes }
            if !execute {
                print("dry-run: would delete \(report.candidates.count) \(modeProfileID) sub-agent conversation(s) (~\(formatMB(totalBytes)))")
            } else {
                print("deleted \(report.deletedCount) \(modeProfileID) sub-agent conversation(s) (~\(formatMB(report.deletedTranscriptBytes)))")
            }
            for candidate in report.candidates {
                print("\(candidate.id)\t\(formatMB(candidate.transcriptBytes))\tmessages=\(candidate.messageCount)")
            }
        } catch {
            fputs("prune error: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    private static func printUsage() {
        let targets = SubAgentModeProfileConversationPruner.supportedModeProfileIDs.sorted().joined(separator: " | ")
        fputs("usage: prune <\(targets)> [--execute]\n", stderr)
        fputs("  default: dry-run listing candidates\n", stderr)
        fputs("  --execute: hard-delete catalog rows and transcript files (server must be stopped)\n", stderr)
    }

    private static func formatMB(_ bytes: Int64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1024.0 / 1024.0)
    }
}
