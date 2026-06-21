import Foundation
import Logging

struct FileEventPeriodicSync: Sendable {
    let eventsDirectory: URL
    let taskStore: ScheduledTaskStore
    let logger: Logger

    func syncFromFile(at eventURL: URL) throws {
        guard let data = try? Data(contentsOf: eventURL),
              let payload = try? JSONDecoder().decode(FileEventPayload.self, from: data),
              payload.type == .periodic,
              let expr = payload.schedule, !expr.isEmpty,
              (try? CronSchedule(expression: expr)) != nil else {
            return
        }
        let trust = FileEventTrustResolver.resolve(for: eventURL)
        let taskID = FileEventQueueLayout.periodicTaskIDPrefix + eventURL.deletingPathExtension().lastPathComponent
        let task = ScheduledTask(
            id: taskID,
            schedule: ScheduledTaskSchedule(kind: .cron, expr: expr),
            payloadKind: .agentTurn,
            payloadText: payload.text,
            recurring: true,
            trust: trust.trust,
            conversationID: payload.conversationID,
            title: eventURL.lastPathComponent
        )
        switch ScheduledTaskCreateScanner.validateCreate(task: task) {
        case .failure(let error):
            logger.warning("file_event_periodic_rejected file=\(eventURL.lastPathComponent) error=\(String(describing: error))")
            return
        case .success:
            break
        }
        _ = try taskStore.upsert(task)
    }

    func removeForDeletedFile(named filename: String) throws {
        let base = (filename as NSString).deletingPathExtension
        let taskID = FileEventQueueLayout.periodicTaskIDPrefix + base
        _ = try taskStore.delete(id: taskID)
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
