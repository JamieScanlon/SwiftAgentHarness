import Foundation
import Logging
import SwiftAgentKit

enum TriggerReplayCLIError: Error, Equatable {
    case usage(String)
    case invalidPayload
    case scheduledTaskNotFound(String)
}

public enum TriggerReplayCLI {
    public static func run(arguments: [String], logger: Logger? = nil) -> Never? {
        guard let code = execute(arguments: arguments, logger: logger) else { return nil }
        exit(code)
    }

    static func execute(arguments: [String], logger: Logger? = nil) -> Int32? {
        guard arguments.count >= 2, arguments[1] == "trigger" else { return nil }
        let resolvedLogger = resolvedLogger(logger)
        var dataDirectoryPath: String?
        var eventsDir: String?
        var inProcess = false
        var jsonOutput = false
        var missed = false
        var payloadJSON: String?
        var deliveryID: String?
        var positional: [String] = []
        var index = 2
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--data-directory":
                index += 1
                guard index < arguments.count else { return fatalUsageReturning("missing value for --data-directory") }
                dataDirectoryPath = arguments[index]
            case "--events-dir":
                index += 1
                guard index < arguments.count else { return fatalUsageReturning("missing value for --events-dir") }
                eventsDir = arguments[index]
            case "--payload":
                index += 1
                guard index < arguments.count else { return fatalUsageReturning("missing value for --payload") }
                payloadJSON = arguments[index]
            case "--delivery-id":
                index += 1
                guard index < arguments.count else { return fatalUsageReturning("missing value for --delivery-id") }
                deliveryID = arguments[index]
            case "--in-process":
                inProcess = true
            case "--json":
                jsonOutput = true
            case "--missed":
                missed = true
            case "--help", "-h":
                printUsage()
                return 0
            default:
                if arg.hasPrefix("--") {
                    return fatalUsageReturning("unknown argument: \(arg)")
                }
                positional.append(arg)
                break
            }
            index += 1
        }
        guard !positional.isEmpty else {
            return fatalUsageReturning("missing subcommand")
        }
        let paths = TriggerReplayPaths.resolve(dataDirectoryPath: dataDirectoryPath, eventsDirectoryPath: eventsDir)
        do {
            let subcommand = positional[0]
            switch subcommand {
            case "webhook":
                try runWebhook(
                    positional: Array(positional.dropFirst()),
                    paths: paths,
                    payloadJSON: payloadJSON,
                    deliveryID: deliveryID,
                    inProcess: inProcess,
                    jsonOutput: jsonOutput,
                    logger: resolvedLogger
                )
            case "file":
                try runFile(
                    positional: Array(positional.dropFirst()),
                    paths: paths,
                    missed: missed,
                    inProcess: inProcess,
                    jsonOutput: jsonOutput,
                    logger: resolvedLogger
                )
            case "snapshot":
                try runSnapshot(
                    positional: Array(positional.dropFirst()),
                    paths: paths,
                    inProcess: inProcess,
                    jsonOutput: jsonOutput,
                    logger: resolvedLogger
                )
            case "audit":
                try runAudit(
                    positional: Array(positional.dropFirst()),
                    paths: paths,
                    inProcess: inProcess,
                    jsonOutput: jsonOutput,
                    logger: resolvedLogger
                )
            case "cron":
                try runCron(
                    positional: Array(positional.dropFirst()),
                    paths: paths,
                    inProcess: inProcess,
                    jsonOutput: jsonOutput,
                    logger: resolvedLogger
                )
            default:
                throw TriggerReplayCLIError.usage("unknown trigger subcommand: \(positional[0])")
            }
        } catch let error as TriggerReplayCLIError {
            if case .usage(let message) = error {
                return fatalUsageReturning(message)
            }
            fputs("trigger error: \(error)\n", stderr)
            return 1
        } catch {
            fputs("trigger error: \(error)\n", stderr)
            return 1
        }
        return 0
    }

    private static func resolvedLogger(_ logger: Logger?) -> Logger {
        logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "TriggerReplayCLI")
        )
    }

    private static func runWebhook(
        positional: [String],
        paths: TriggerReplayPaths,
        payloadJSON: String?,
        deliveryID: String?,
        inProcess: Bool,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        guard positional.count >= 2 else {
            throw TriggerReplayCLIError.usage("usage: trigger webhook test|fire <route> --payload '<json>'")
        }
        let command = positional[0]
        let routeName = positional[1]
        guard let payloadJSON else {
            throw TriggerReplayCLIError.usage("missing --payload")
        }
        let payload = try parsePayloadJSON(payloadJSON)
        let store = WebhookRouteStore(
            staticRoutes: [],
            dynamicStore: WebhookDynamicRouteStore(fileURL: paths.webhookSubscriptionsURL)
        )
        let builder = WebhookReplayBuilder(routeStore: store)
        switch command {
        case "test":
            let route = try store.route(named: routeName)
            let rendered = try builder.renderedPayload(routeName: routeName, payload: payload)
            let trigger = try builder.build(routeName: routeName, payload: payload, deliveryID: deliveryID)
            let preview = TriggerReplayService(
                dispatch: TriggerReplayHarness.makeDispatch(createConversation: { _ in UUID() }, logger: logger)
            )
                .dryRunPreview(trigger: trigger)
            let result = TriggerReplayDryRunResult(
                mode: "dry-run",
                route: routeName,
                renderedPayload: rendered,
                deliverOnly: route?.deliverOnly,
                trigger: preview.trigger,
                prompt: preview.prompt
            )
            printOutput(result, json: true)
        case "fire":
            let route = try store.route(named: routeName)
            guard let route else {
                throw TriggerReplayCLIError.usage("route not found: \(routeName)")
            }
            if route.deliverOnly {
                let rendered = try builder.renderedPayload(routeName: routeName, payload: payload)
                let extra = WebhookPromptTemplate.renderExtras(route.deliverExtra, payload: payload)
                let registry = ChannelListenerRegistry.load(
                    dataDirectory: paths.dataDirectory,
                    ingress: ChannelIngressAdapter(
                        dispatch: TriggerReplayHarness.makeDispatch(createConversation: { _ in UUID() }, logger: logger)
                    ),
                    logger: logger,
                    enabled: false,
                    configURL: nil
                )
                let delivery = WebhookDirectDelivery(channelRegistry: registry)
                let outcome = try awaitDeliverOnly {
                    await delivery.deliver(route: route, rendered: rendered, extra: extra)
                }
                if jsonOutput {
                    let result = TriggerReplayDeliverOnlyResult(
                        mode: "deliver-only",
                        route: routeName,
                        renderedPayload: rendered,
                        outcome: deliverOnlyOutcomeLabel(outcome)
                    )
                    printOutput(result, json: true)
                } else {
                    print("deliver-only '\(routeName)': \(outcome)")
                }
                return
            }
            let trigger = try builder.build(routeName: routeName, payload: payload, deliveryID: deliveryID)
            try fireTrigger(trigger, paths: paths, inProcess: inProcess, jsonOutput: jsonOutput, logger: logger)
        default:
            throw TriggerReplayCLIError.usage("usage: trigger webhook test|fire <route>")
        }
    }

    private static func runFile(
        positional: [String],
        paths: TriggerReplayPaths,
        missed: Bool,
        inProcess: Bool,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        guard positional.count >= 2, positional[0] == "replay" else {
            throw TriggerReplayCLIError.usage("usage: trigger file replay <event.json>")
        }
        let eventURL = URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath)
        if inProcess {
            let service = TriggerReplayHarness.makeReplayService(logger: logger)
            let result = try awaitInProcess {
                try await service.replayFile(at: eventURL, eventsDirectory: paths.eventsDirectory, missed: missed)
            }
            printInProcess(result, json: jsonOutput)
            return
        }
        guard let data = try? Data(contentsOf: eventURL),
              let filePayload = try? JSONDecoder().decode(FileEventPayload.self, from: data) else {
            throw TriggerReplayError.unreadableEventFile
        }
        let trust = FileEventTrustResolver.resolve(for: eventURL)
        let trigger = FileEventIngressAdapter().makeTrigger(
            payload: filePayload,
            trust: trust,
            eventURL: eventURL,
            missed: missed,
            eventsDirectory: paths.eventsDirectory
        )
        let enqueued = try TriggerReplayHarness.enqueue(trigger: trigger, paths: paths)
        printOutput(enqueued, json: jsonOutput)
    }

    private static func runSnapshot(
        positional: [String],
        paths: TriggerReplayPaths,
        inProcess: Bool,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        guard positional.count >= 2, positional[0] == "replay" else {
            throw TriggerReplayCLIError.usage("usage: trigger snapshot replay <trigger.json>")
        }
        let snapshotURL = URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath)
        if inProcess {
            let service = TriggerReplayHarness.makeReplayService(logger: logger)
            let result = try awaitInProcess {
                try await service.replaySnapshot(at: snapshotURL)
            }
            printInProcess(result, json: jsonOutput)
            return
        }
        guard let data = try? Data(contentsOf: snapshotURL),
              let trigger = try? JSONDecoder().decode(HarnessTrigger.self, from: data) else {
            throw TriggerReplayError.unreadableSnapshot
        }
        let enqueued = try TriggerReplayHarness.enqueue(trigger: trigger, paths: paths)
        printOutput(enqueued, json: jsonOutput)
    }

    private static func runAudit(
        positional: [String],
        paths: TriggerReplayPaths,
        inProcess: Bool,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        guard positional.count >= 2, positional[0] == "replay" else {
            throw TriggerReplayCLIError.usage("usage: trigger audit replay <trigger-id>")
        }
        let triggerID = positional[1]
        let trigger = try paths.snapshotStore.load(triggerID: triggerID)
        if inProcess {
            let service = TriggerReplayHarness.makeReplayService(logger: logger)
            let result = try awaitInProcess {
                try await service.replay(trigger)
            }
            printInProcess(result, json: jsonOutput)
            return
        }
        let enqueued = try TriggerReplayHarness.enqueue(trigger: trigger, paths: paths)
        printOutput(enqueued, json: jsonOutput)
    }

    private static func runCron(
        positional: [String],
        paths: TriggerReplayPaths,
        inProcess: Bool,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        guard positional.count >= 2, positional[0] == "fire" else {
            throw TriggerReplayCLIError.usage("usage: trigger cron fire <task-id>")
        }
        let taskID = positional[1]
        let store = ScheduledTaskStore(fileURL: paths.scheduledTasksURL)
        guard let task = try store.task(id: taskID) else {
            throw TriggerReplayCLIError.scheduledTaskNotFound(taskID)
        }
        let trigger = ScheduledTaskTriggerBuilder.makeTrigger(from: task)
        if inProcess {
            let service = TriggerReplayHarness.makeReplayService(logger: logger)
            let result = try awaitInProcess {
                try await service.replay(trigger)
            }
            printInProcess(result, json: jsonOutput)
            return
        }
        let enqueued = try TriggerReplayHarness.enqueue(trigger: trigger, paths: paths)
        printOutput(enqueued, json: jsonOutput)
    }

    private static func fireTrigger(
        _ trigger: HarnessTrigger,
        paths: TriggerReplayPaths,
        inProcess: Bool,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        if inProcess {
            let service = TriggerReplayHarness.makeReplayService(logger: logger)
            let result = try awaitInProcess {
                try await service.replay(trigger)
            }
            printInProcess(result, json: jsonOutput)
            return
        }
        let enqueued = try TriggerReplayHarness.enqueue(trigger: trigger, paths: paths)
        printOutput(enqueued, json: jsonOutput)
    }

    private static func parsePayloadJSON(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TriggerReplayCLIError.invalidPayload
        }
        return object
    }

    private static func awaitInProcess(_ work: @escaping @Sendable () async throws -> TriggerActivationResult) throws -> TriggerActivationResult {
        final class ResultBox: @unchecked Sendable {
            var value: Result<TriggerActivationResult, Error>?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    box.value = .success(try await work())
                } catch {
                    box.value = .failure(error)
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        switch box.value {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw TriggerReplayError.unreadableSnapshot
        }
    }

    private static func awaitDeliverOnly(_ work: @escaping @Sendable () async -> WebhookDeliverOnlyOutcome) throws -> WebhookDeliverOnlyOutcome {
        final class ResultBox: @unchecked Sendable {
            var value: WebhookDeliverOnlyOutcome?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                box.value = await work()
                semaphore.signal()
            }
        }
        semaphore.wait()
        guard let value = box.value else {
            throw TriggerReplayCLIError.usage("deliver-only replay failed")
        }
        return value
    }

    private static func deliverOnlyOutcomeLabel(_ outcome: WebhookDeliverOnlyOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .deliveryFailed(let reason): return "failed:\(reason)"
        case .targetMissing: return "target-missing"
        }
    }

    private static func printInProcess(_ result: TriggerActivationResult, json: Bool) {
        let payload = TriggerReplayInProcessResult(
            mode: "in-process",
            decision: result.decision.rawValue,
            sessionID: result.sessionID?.uuidString
        )
        printOutput(payload, json: json)
    }

    private static func printOutput<T: Encodable>(_ value: T, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else if let enqueued = value as? TriggerReplayEnqueueResult {
            print("enqueued \(enqueued.eventFile) -> \(enqueued.eventsDirectory)")
            print(enqueued.message)
        } else if let dry = value as? TriggerReplayDryRunResult {
            print("route: \(dry.route ?? "n/a")")
            if let rendered = dry.renderedPayload {
                print("rendered: \(rendered)")
            }
            print(dry.prompt.userMessageBody)
        } else if let inProc = value as? TriggerReplayInProcessResult {
            print("decision: \(inProc.decision) session: \(inProc.sessionID ?? "nil")")
        }
    }

    private static func fatalUsageReturning(_ message: String) -> Int32 {
        fputs("trigger error: \(message)\n", stderr)
        printUsage()
        return 1
    }

    private static func printUsage() {
        print("""
        trigger — replay captured triggers

        Invoke as a subcommand of the host CLI: <executable> trigger <subcommand> ...

        Usage:
          trigger webhook test <route> --payload '<json>' [--data-directory <path>] [--json]
          trigger webhook fire  <route> --payload '<json>' [--delivery-id <id>] [--in-process] [--json]
          trigger file replay <event.json> [--missed] [--in-process] [--json]
          trigger snapshot replay <trigger.json> [--in-process] [--json]
          trigger audit replay <trigger-id> [--in-process] [--json]
          trigger cron fire <task-id> [--in-process] [--json]

        Flags:
          --data-directory    Trigger config directory (webhooks, cron, snapshots; ephemeral temp when omitted)
          --events-dir        Override events directory (or TRIGGER_EVENTS_DIR)
          --delivery-id       Optional webhook delivery correlation id
          --missed            Replay file events as missed periodic sync
          --in-process        Synchronous replay without enqueueing (CI/dev)
          --json              Machine-readable stdout
        """)
    }
}
