import Foundation
import Logging

/// Registers `periodic` event files as recurring scheduled tasks.
///
/// The events directory serves two roles: an event *queue* (a dropped `immediate` file is itself a
/// trigger) and a *configuration store* (a `periodic` or `one-shot` file registers a scheduled task
/// and unregisters it when deleted). Registrations go through ``TriggerRegistrationService`` so they
/// get creator stamping, trust clamping, and an audit row — which is also what makes them visible to
/// `schedule_list` instead of being orphaned rows nobody can see or delete.
struct FileEventPeriodicSync: Sendable {
    let eventsDirectory: URL
    let registration: TriggerRegistrationService
    let logger: Logger

    /// The drop directory is a local trusted path, so the *creator* is the machine owner. The
    /// *content* trust still comes from the `.trust` sidecar and defaults to `unknown-party` —
    /// the filesystem grants no trust by itself.
    private var authority: RegistrationAuthority { .localFileDrop() }

    func syncFromFile(at eventURL: URL) throws {
        guard let data = try? Data(contentsOf: eventURL),
              let payload = try? JSONDecoder().decode(FileEventPayload.self, from: data),
              payload.type == .periodic,
              let expr = payload.schedule, !expr.isEmpty,
              (try? CronSchedule(expression: expr)) != nil else {
            return
        }
        let trust = FileEventTrustResolver.resolve(for: eventURL)
        let taskID = FileEventQueueLayout.taskID(
            forSubscription: eventURL.deletingPathExtension().lastPathComponent,
            kind: .periodic
        )
        // Carried the same way ``FileEventScheduledSync`` carries it. Without this a periodic
        // subscription written as a follow-up — by the harness itself, through
        // `writeSubscription` — lost its lineage the moment it registered, so every fire looked
        // like a fresh root and nothing tied it back to what asked for it.
        let correlation = TriggerCorrelation.fromPayload(
            rootId: payload.rootId,
            parentTriggerId: payload.parentTriggerId,
            correlationId: payload.correlationId,
            fallbackTriggerID: taskID
        )
        let spec = ScheduleRegistrationSpec(
            id: taskID,
            schedule: ScheduledTaskSchedule(kind: .cron, expr: expr),
            payloadKind: .agentTurn,
            payloadText: payload.text,
            recurring: true,
            conversationID: payload.conversationID,
            title: eventURL.lastPathComponent,
            correlation: correlation,
            requestedTrust: trust.trust,
            durable: true,
            // `FileEventPayload.timezone` was decoded and then dropped: a sidecar could ask
            // for `America/Los_Angeles` and be scheduled in the host's zone with no error at
            // all. An unrecognised identifier is now refused by the validator, not ignored.
            timezone: payload.timezone
        )
        do {
            _ = try registration.registerSchedule(spec, authority: authority)
        } catch {
            logger.warning("file_event_periodic_rejected file=\(eventURL.lastPathComponent) error=\(String(describing: error))")
        }
    }

    func removeForDeletedFile(named filename: String) throws {
        let base = (filename as NSString).deletingPathExtension
        let taskID = FileEventQueueLayout.taskID(forSubscription: base, kind: .periodic)
        _ = try registration.deleteSchedule(id: taskID, authority: authority)
    }

    func syncAllPeriodicFiles() throws {
        let urls = try listEventJSONFiles()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(FileEventPayload.self, from: data),
                  payload.type == .periodic else { continue }
            try syncFromFile(at: url)
        }
    }

    private func listEventJSONFiles() throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: eventsDirectory.path) else { return [] }
        return try fm.contentsOfDirectory(at: eventsDirectory, includingPropertiesForKeys: nil)
            .filter { FileEventQueueLayout.isEventJSON($0) }
    }
}
