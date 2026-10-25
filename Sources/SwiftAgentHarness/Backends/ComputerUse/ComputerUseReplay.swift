import Foundation

/// A thumbnail the session keeps of one observation, for the post-run replay. Observations themselves are
/// dropped once they fall out of the citing window.
public struct ComputerUseReplayFrame: Sendable, Equatable {
    public var observationID: ObservationID
    public var at: Date
    public var app: String?
    public var image: PresentationImage
}

/// A replay thumbnail as stored: the image lives in the session blob store.
public struct ComputerUseReplayThumbnail: Sendable, Codable, Equatable {
    public var observationID: ObservationID
    public var at: Date
    public var app: String?
    public var width: Int
    public var height: Int
    public var mediaType: String
    public var blobID: String
}

/// A replay's listing row.
public struct ComputerUseReplaySummary: Sendable, Codable, Equatable {
    public var lifecycleID: String
    public var target: String
    public var startedAt: Date
    public var endedAt: Date
    public var terminalReason: ComputerUseTerminalReason?
    public var steps: Int
    public var actionCount: Int
    public var thumbnailCount: Int
}

/// What a specialist session did, for the user to review afterwards: the action log plus observation thumbnails.
/// It is a record for humans, not a script to re-execute.
public struct ComputerUseReplay: Sendable, Codable, Equatable {
    public var sessionID: UUID
    public var parentConversationID: UUID
    public var lifecycleID: String
    public var target: String
    public var startedAt: Date
    public var endedAt: Date
    public var terminalReason: ComputerUseTerminalReason?
    public var steps: Int
    public var records: [ComputerUseActionRecord]
    public var thumbnails: [ComputerUseReplayThumbnail]

    public var summary: ComputerUseReplaySummary {
        ComputerUseReplaySummary(
            lifecycleID: lifecycleID,
            target: target,
            startedAt: startedAt,
            endedAt: endedAt,
            terminalReason: terminalReason,
            steps: steps,
            actionCount: records.count,
            thumbnailCount: thumbnails.count
        )
    }
}

extension ComputerUseReplay {
    /// Builds the replay from a finished session, storing each thumbnail through `storeThumbnail`, which returns
    /// the blob id.
    init(
        session: ComputerUseSession,
        parentConversationID: UUID,
        lifecycleID: String,
        targetLabel: String,
        endedAt: Date = Date(),
        storeThumbnail: (Data) throws -> String
    ) async throws {
        var thumbnails: [ComputerUseReplayThumbnail] = []
        for frame in await session.replayFrames {
            thumbnails.append(ComputerUseReplayThumbnail(
                observationID: frame.observationID,
                at: frame.at,
                app: frame.app,
                width: frame.image.width,
                height: frame.image.height,
                mediaType: frame.image.mediaType,
                blobID: try storeThumbnail(frame.image.data)
            ))
        }
        self.init(
            sessionID: session.id,
            parentConversationID: parentConversationID,
            lifecycleID: lifecycleID,
            target: targetLabel,
            startedAt: session.startedAt,
            endedAt: endedAt,
            terminalReason: await session.terminalReason,
            steps: await session.stepCount,
            records: await session.auditLog,
            thumbnails: thumbnails
        )
    }
}

extension JSONEncoder {
    /// Storage form of a replay document. Dates keep full precision; REST re-encodes them as ISO-8601.
    static var computerUseReplay: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var computerUseReplay: JSONDecoder { JSONDecoder() }
}

struct ComputerUseReplayIndexEntry: Sendable {
    var replay: ComputerUseReplay
    /// The stored replay document.
    var documentBlobID: String
    var loadBlob: @Sendable (String) throws -> Data
}

/// Recent replays per user conversation, newest first, so surfaces can list and open them.
actor ComputerUseReplayIndex {
    private let capacityPerConversation: Int
    private var entries: [UUID: [ComputerUseReplayIndexEntry]] = [:]

    init(capacityPerConversation: Int = 50) {
        self.capacityPerConversation = max(1, capacityPerConversation)
    }

    func record(_ replay: ComputerUseReplay, documentBlobID: String, loadBlob: @escaping @Sendable (String) throws -> Data) {
        var list = entries[replay.parentConversationID] ?? []
        list.removeAll { $0.replay.lifecycleID == replay.lifecycleID }
        list.insert(ComputerUseReplayIndexEntry(replay: replay, documentBlobID: documentBlobID, loadBlob: loadBlob), at: 0)
        list.sort { $0.replay.endedAt > $1.replay.endedAt }
        entries[replay.parentConversationID] = Array(list.prefix(capacityPerConversation))
    }

    func summaries(parent conversationID: UUID) -> [ComputerUseReplaySummary] {
        (entries[conversationID] ?? []).map(\.replay.summary)
    }

    func entry(parent conversationID: UUID, lifecycleID: String) -> ComputerUseReplayIndexEntry? {
        entries[conversationID]?.first { $0.replay.lifecycleID == lifecycleID }
    }
}
