import Foundation
import Logging

struct FileEventConsumePipeline: Sendable {
    let eventsDirectory: URL
    let parser: FileEventPayloadParser
    let ingress: FileEventIngressAdapter
    let dispatch: TriggerDispatchService
    let logger: Logger

    func consume(eventURL: URL, missed: Bool = false) async {
        guard FileEventQueueLayout.isEventJSON(eventURL),
              FileManager.default.fileExists(atPath: eventURL.path) else { return }
        let processingDir = FileEventQueueLayout.processingDirectory(eventsDirectory: eventsDirectory)
        try? FileManager.default.createDirectory(at: processingDir, withIntermediateDirectories: true)
        let staged = processingDir.appendingPathComponent("\(UUID().uuidString)-\(eventURL.lastPathComponent)")
        let inboxTrustURL = FileEventQueueLayout.trustSidecarURL(for: eventURL)
        let stagedTrustURL = FileEventQueueLayout.trustSidecarURL(for: staged)
        do {
            try FileManager.default.moveItem(at: eventURL, to: staged)
        } catch {
            logger.warning("file_event_rename_failed path=\(eventURL.lastPathComponent) error=\(String(describing: error))")
            return
        }
        if FileManager.default.fileExists(atPath: inboxTrustURL.path) {
            try? FileManager.default.moveItem(at: inboxTrustURL, to: stagedTrustURL)
        }
        let trust = FileEventTrustResolver.resolve(for: staged)
        switch await parser.parse(at: staged) {
        case .skipped:
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: stagedTrustURL)
            return
        case .parsed(let payload):
            if payload.type == .periodic {
                try? FileManager.default.moveItem(at: staged, to: eventURL)
                if FileManager.default.fileExists(atPath: stagedTrustURL.path) {
                    try? FileManager.default.moveItem(at: stagedTrustURL, to: inboxTrustURL)
                }
                return
            }
            let trigger = ingress.makeTrigger(
                payload: payload,
                trust: trust,
                eventURL: eventURL,
                missed: missed,
                eventsDirectory: eventsDirectory
            )
            _ = try? await dispatch.ingest(trigger)
            cleanupAfterSuccess(originalEventURL: eventURL, payload: payload, stagedURL: staged, trust: trust)
        }
    }

    private func cleanupAfterSuccess(
        originalEventURL: URL,
        payload: FileEventPayload,
        stagedURL: URL,
        trust: FileEventTrustSidecar
    ) {
        try? FileManager.default.removeItem(at: stagedURL)
        let stagedTrustURL = FileEventQueueLayout.trustSidecarURL(for: stagedURL)
        if FileManager.default.fileExists(atPath: stagedTrustURL.path) {
            try? FileManager.default.removeItem(at: stagedTrustURL)
        }
        switch payload.type {
        case .immediate, .oneShot:
            try? FileManager.default.removeItem(at: originalEventURL)
            let trustURL = FileEventQueueLayout.trustSidecarURL(for: originalEventURL)
            if FileManager.default.fileExists(atPath: trustURL.path) {
                try? FileManager.default.removeItem(at: trustURL)
            }
        case .periodic:
            break
        }
        _ = trust
    }
}
