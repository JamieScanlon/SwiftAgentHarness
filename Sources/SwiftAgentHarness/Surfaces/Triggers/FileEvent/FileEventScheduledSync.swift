import Foundation
import Logging

enum FileEventScheduledFileKind {
    static let oneShotTaskIDPrefix = "file-one-shot:"
}

struct FileEventScheduledSync: Sendable {
    let eventsDirectory: URL
    let taskStore: ScheduledTaskStore
    let logger: Logger

    func syncFutureOneShot(at eventURL: URL, payload: FileEventPayload) throws -> Bool {
        guard payload.type == .oneShot,
              let atRaw = payload.at,
              let atDate = ISO8601DateFormatter().date(from: atRaw),
              atDate > Date() else { return false }
        let trust = FileEventTrustResolver.resolve(for: eventURL)
        let taskID = FileEventScheduledFileKind.oneShotTaskIDPrefix + eventURL.deletingPathExtension().lastPathComponent
        let correlation = TriggerCorrelation.fromPayload(
            rootId: payload.rootId,
            parentTriggerId: payload.parentTriggerId,
            correlationId: payload.correlationId,
            fallbackTriggerID: taskID
        )
        let task = ScheduledTask(
            id: taskID,
            schedule: ScheduledTaskSchedule(kind: .at, at: atRaw),
            payloadKind: .agentTurn,
            payloadText: payload.text,
            recurring: false,
            trust: trust.trust,
            conversationID: payload.conversationID,
            title: eventURL.lastPathComponent,
            correlation: correlation
        )
        switch ScheduledTaskCreateScanner.validateCreate(task: task) {
        case .failure(let error):
            logger.warning("file_event_one_shot_rejected file=\(eventURL.lastPathComponent) error=\(String(describing: error))")
            return false
        case .success:
            break
        }
        _ = try taskStore.upsert(task)
        return true
    }

    func removeForDeletedFile(named filename: String) throws {
        let base = (filename as NSString).deletingPathExtension
        _ = try taskStore.delete(id: FileEventQueueLayout.periodicTaskIDPrefix + base)
        _ = try taskStore.delete(id: FileEventScheduledFileKind.oneShotTaskIDPrefix + base)
    }
}
