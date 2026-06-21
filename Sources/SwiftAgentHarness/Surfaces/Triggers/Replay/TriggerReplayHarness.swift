import Foundation
import Logging
import SwiftAgentKit

struct TriggerReplayPathConfiguration: Sendable {
    var dataDirectory: URL
    var eventsDirectory: URL?
}

struct TriggerReplayPaths: Sendable {
    let dataDirectory: URL
    let eventsDirectory: URL
    let webhookSubscriptionsURL: URL
    let scheduledTasksURL: URL
    let snapshotStore: TriggerSnapshotStore

    init(_ configuration: TriggerReplayPathConfiguration) {
        dataDirectory = configuration.dataDirectory
        if let override = configuration.eventsDirectory {
            eventsDirectory = override
        } else if let raw = ProcessInfo.processInfo.environment["TRIGGER_EVENTS_DIR"],
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            eventsDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            eventsDirectory = FileEventQueueLayout.resolveEventsDirectory(dataDirectory: dataDirectory)
        }
        webhookSubscriptionsURL = dataDirectory.appendingPathComponent("webhook_subscriptions.json")
        scheduledTasksURL = dataDirectory.appendingPathComponent("scheduled_tasks.json")
        snapshotStore = TriggerSnapshotStore(dataDirectory: dataDirectory)
    }

    static func resolve(dataDirectoryPath: String?, eventsDirectoryPath: String?) -> TriggerReplayPaths {
        let dataDirectory: URL
        if let raw = dataDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            dataDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("trigger-replay-\(UUID().uuidString)", isDirectory: true)
        }
        let eventsDirectory: URL?
        if let raw = eventsDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            eventsDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            eventsDirectory = nil
        }
        return TriggerReplayPaths(TriggerReplayPathConfiguration(
            dataDirectory: dataDirectory,
            eventsDirectory: eventsDirectory
        ))
    }
}

struct TriggerReplayEnqueueResult: Codable, Sendable, Equatable {
    var mode: String
    var eventsDirectory: String
    var eventFile: String
    var triggerID: String
    var message: String
}

struct TriggerReplayInProcessResult: Codable, Sendable, Equatable {
    var mode: String
    var decision: String
    var sessionID: String?
}

struct TriggerReplayDryRunResult: Codable, Sendable, Equatable {
    var mode: String
    var route: String?
    var renderedPayload: String?
    var deliverOnly: Bool?
    var trigger: HarnessTrigger
    var prompt: TriggerPromptBuildResult
}

struct TriggerReplayDeliverOnlyResult: Codable, Sendable, Equatable {
    var mode: String
    var route: String
    var renderedPayload: String
    var outcome: String
}

enum TriggerReplayHarness {
    static func makeReplayService(
        createConversation: @escaping @Sendable (String?) async throws -> UUID = { _ in UUID() },
        logger: Logger? = nil
    ) -> TriggerReplayService {
        let dispatch = makeDispatch(createConversation: createConversation, logger: logger)
        return TriggerReplayService(dispatch: dispatch)
    }

    static func makeDispatch(
        createConversation: @escaping @Sendable (String?) async throws -> UUID,
        logger: Logger? = nil
    ) -> TriggerDispatchService {
        let resolved = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "TriggerReplayHarness")
        )
        let policy = TriggerActivationPolicy(
            idempotency: TriggerIdempotencyGate(dedupe: ReplayHarnessDedupe()),
            rateLimit: TriggerRateLimitGate(maxPerWindow: 10_000),
            costCeiling: TriggerCostCeilingGate(maxPerWindow: 10_000),
            auditLog: TriggerAuditLog(logger: resolved)
        )
        let router = TriggerSessionRouter(sessionIndex: TriggerSessionIndex(createConversation: createConversation))
        return TriggerDispatchService(
            activationPolicy: policy,
            sessionRouter: router,
            promptBuilder: TriggerPromptBuilder(),
            runtime: ReplayStdoutRuntime()
        )
    }

    static func enqueue(trigger: HarnessTrigger, paths: TriggerReplayPaths) throws -> TriggerReplayEnqueueResult {
        let fresh = TriggerReplayService.freshReplayID(trigger)
        let basename = "replay-\(UUID().uuidString)"
        let preview = TriggerPromptBuilder().build(trigger: fresh)
        var text = preview.userMessageBody
        if let reminder = preview.systemReminder {
            text = reminder + "\n\n" + text
        }
        try FileEventQueueWriter.writeImmediate(
            eventsDirectory: paths.eventsDirectory,
            basename: basename,
            text: text,
            trust: FileEventTrustSidecar(
                trust: .knownParty,
                source: "replay-cli",
                routeName: fresh.sourceMetadata["routeName"]
            )
        )
        return TriggerReplayEnqueueResult(
            mode: "enqueued",
            eventsDirectory: paths.eventsDirectory.path,
            eventFile: "\(basename).json",
            triggerID: fresh.id,
            message: "Event enqueued; ensure the host file-event watcher is running to consume it."
        )
    }
}

actor ReplayHarnessDedupe: TriggerDedupeChecking {
    func dedupePeek(key: String) async throws -> Bool { false }
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool { true }
}

struct ReplayStdoutRuntime: TriggerRuntimeDispatching {
    func dispatchTriggerMessage(
        conversationID: UUID,
        text: String,
        systemReminder: String?,
        inputTrustRaw: String?,
        enableTools: Bool,
        enableAgents: Bool,
        originSurface: String?,
        originSenderID: String?
    ) async throws {}
}
