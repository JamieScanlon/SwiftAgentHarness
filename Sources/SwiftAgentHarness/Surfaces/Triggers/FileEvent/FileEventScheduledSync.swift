import Foundation
import Logging

enum FileEventScheduledFileKind {
    static let oneShotTaskIDPrefix = "file-one-shot:"
}

/// Registers future-dated `one-shot` event files as one-shot scheduled tasks, so a drop whose fire
/// time has not arrived is deferred rather than consumed immediately.
///
/// Like ``FileEventPeriodicSync``, registration goes through ``TriggerRegistrationService`` rather
/// than writing the task store directly.
struct FileEventScheduledSync: Sendable {
    let eventsDirectory: URL
    let registration: TriggerRegistrationService
    let logger: Logger

    private var authority: RegistrationAuthority { .localFileDrop() }

    func syncFutureOneShot(at eventURL: URL, payload: FileEventPayload) throws -> Bool {
        guard payload.type == .oneShot,
              let atRaw = payload.at,
              let atDate = ISO8601DateFormatter().date(from: atRaw),
              atDate > Date() else { return false }
        let trust = FileEventTrustResolver.resolve(for: eventURL)
        let taskID = FileEventQueueLayout.taskID(
            forSubscription: eventURL.deletingPathExtension().lastPathComponent,
            kind: .oneShot
        )
        let correlation = TriggerCorrelation.fromPayload(
            rootId: payload.rootId,
            parentTriggerId: payload.parentTriggerId,
            correlationId: payload.correlationId,
            fallbackTriggerID: taskID
        )
        let spec = ScheduleRegistrationSpec(
            id: taskID,
            schedule: ScheduledTaskSchedule(kind: .at, at: atRaw),
            payloadKind: .agentTurn,
            payloadText: payload.text,
            recurring: false,
            conversationID: payload.conversationID,
            title: eventURL.lastPathComponent,
            correlation: correlation,
            requestedTrust: trust.trust,
            durable: true
        )
        do {
            _ = try registration.registerSchedule(spec, authority: authority)
            return true
        } catch {
            logger.warning("file_event_one_shot_rejected file=\(eventURL.lastPathComponent) error=\(String(describing: error))")
            return false
        }
    }

    func removeForDeletedFile(named filename: String) throws {
        let base = (filename as NSString).deletingPathExtension
        // Both prefixes are probed: the file's own type is not knowable once it has been deleted,
        // so removal has to cover either kind it might have been.
        _ = try registration.deleteSchedule(
            id: FileEventQueueLayout.taskID(forSubscription: base, kind: .periodic),
            authority: authority
        )
        _ = try registration.deleteSchedule(
            id: FileEventQueueLayout.taskID(forSubscription: base, kind: .oneShot),
            authority: authority
        )
    }
}
