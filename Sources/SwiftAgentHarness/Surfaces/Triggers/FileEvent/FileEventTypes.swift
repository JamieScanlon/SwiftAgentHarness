import Foundation

enum FileEventKind: String, Codable, Sendable, Equatable {
    case immediate
    case oneShot = "one-shot"
    case periodic
}

struct FileEventPayload: Codable, Sendable, Equatable {
    var type: FileEventKind
    var text: String
    var channelId: String?
    var at: String?
    var schedule: String?
    var timezone: String?
    var conversationID: String?
}

struct FileEventTrustSidecar: Codable, Sendable, Equatable {
    var trust: CommEnvelopeOriginTrust
    var source: String?
    var routeName: String?
    var initiatorId: String?

    init(
        trust: CommEnvelopeOriginTrust = .unknownParty,
        source: String? = nil,
        routeName: String? = nil,
        initiatorId: String? = nil
    ) {
        self.trust = trust
        self.source = source
        self.routeName = routeName
        self.initiatorId = initiatorId
    }
}

enum FileEventQueueLayout {
    static let processingSubdirectory = ".processing"
    static let jsonExtension = "json"
    static let trustExtension = "trust"
    static let periodicTaskIDPrefix = "file-periodic:"

    static func processingDirectory(eventsDirectory: URL) -> URL {
        eventsDirectory.appendingPathComponent(processingSubdirectory, isDirectory: true)
    }

    static func trustSidecarURL(for eventURL: URL) -> URL {
        eventURL.deletingPathExtension().appendingPathExtension(trustExtension)
    }

    static func isEventJSON(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == jsonExtension
            && !url.lastPathComponent.hasPrefix(".")
    }

    static func resolveEventsDirectory(dataDirectory: URL) -> URL {
        if let raw = ProcessInfo.processInfo.environment["TRIGGER_EVENTS_DIR"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return dataDirectory.deletingLastPathComponent().appendingPathComponent("events", isDirectory: true)
    }
}
