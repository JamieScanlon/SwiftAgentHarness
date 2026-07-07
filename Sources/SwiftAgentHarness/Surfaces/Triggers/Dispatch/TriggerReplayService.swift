import Foundation

struct TriggerReplayPreview: Codable, Sendable, Equatable {
    var trigger: HarnessTrigger
    var prompt: TriggerPromptBuildResult
}

struct TriggerReplayService: Sendable {
    let dispatch: TriggerDispatchService
    let eventsDirectory: URL?
    let ingress: FileEventIngressAdapter
    let promptBuilder: TriggerPromptBuilder

    init(
        dispatch: TriggerDispatchService,
        eventsDirectory: URL? = nil,
        ingress: FileEventIngressAdapter = FileEventIngressAdapter(),
        promptBuilder: TriggerPromptBuilder = TriggerPromptBuilder()
    ) {
        self.dispatch = dispatch
        self.eventsDirectory = eventsDirectory
        self.ingress = ingress
        self.promptBuilder = promptBuilder
    }

    func replay(_ trigger: HarnessTrigger, freshID: Bool = true) async throws -> TriggerActivationResult {
        let resolved = freshID ? Self.freshReplayID(trigger) : trigger
        return try await dispatch.ingest(resolved)
    }

    func replayFile(at eventURL: URL, eventsDirectory: URL? = nil, missed: Bool = false, freshID: Bool = true) async throws -> TriggerActivationResult {
        let dir = eventsDirectory ?? self.eventsDirectory ?? eventURL.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: eventURL),
              let payload = try? JSONDecoder().decode(FileEventPayload.self, from: data) else {
            throw TriggerReplayError.unreadableEventFile
        }
        let trust = FileEventTrustResolver.resolve(for: eventURL)
        let trigger = ingress.makeTrigger(
            payload: payload,
            trust: trust,
            eventURL: eventURL,
            missed: missed,
            eventsDirectory: dir
        )
        return try await replay(trigger, freshID: freshID)
    }

    func replaySnapshot(at url: URL, freshID: Bool = true) async throws -> TriggerActivationResult {
        guard let data = try? Data(contentsOf: url),
              let trigger = try? JSONDecoder().decode(HarnessTrigger.self, from: data) else {
            throw TriggerReplayError.unreadableSnapshot
        }
        return try await replay(trigger, freshID: freshID)
    }

    func dryRunPreview(trigger: HarnessTrigger) -> TriggerReplayPreview {
        TriggerReplayPreview(trigger: trigger, prompt: promptBuilder.build(trigger: trigger))
    }

    static func freshReplayID(_ trigger: HarnessTrigger) -> HarnessTrigger {
        var updated = trigger
        updated.id = "replay:\(UUID().uuidString):\(trigger.id)"
        let parentCorrelation = trigger.effectiveCorrelation()
        updated.correlation = TriggerCorrelation(
            rootId: parentCorrelation.rootId,
            parentTriggerId: trigger.id,
            correlationId: parentCorrelation.correlationId,
            followUpKind: "replay"
        )
        return updated
    }
}

enum TriggerReplayError: Error, Equatable {
    case unreadableEventFile
    case unreadableSnapshot
}
