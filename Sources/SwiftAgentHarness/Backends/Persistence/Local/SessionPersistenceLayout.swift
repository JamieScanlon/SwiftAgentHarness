//
//  On-disk layout for LocalHarnessSessionPersistence (harness README "Layout on disk").
//

import Foundation

enum SessionPersistenceLayout {
    static let defaultAgentId = "default"

    static func catalogURL(root: URL) -> URL {
        root.appendingPathComponent("catalog.sqlite", isDirectory: false)
    }

    static func agentSessionsDirectory(root: URL, agentId: String) -> URL {
        root.appendingPathComponent("agents/\(agentId)/sessions", isDirectory: true)
    }

    /// README `agent_dir`: `agents/<agentId>/` (sessions live under `sessions/`).
    static func agentRootDirectory(root: URL, agentId: String) -> URL {
        root.appendingPathComponent("agents/\(agentId)", isDirectory: true)
    }

    static func agentAuthProfilesURL(root: URL, agentId: String) -> URL {
        agentRootDirectory(root: root, agentId: agentId).appendingPathComponent("auth-profiles.json", isDirectory: false)
    }

    static func transcriptURL(root: URL, agentId: String, conversationId: UUID) -> URL {
        agentSessionsDirectory(root: root, agentId: agentId)
            .appendingPathComponent("\(conversationId.uuidString).jsonl", isDirectory: false)
    }

    static func transcriptLockURL(root: URL, agentId: String, conversationId: UUID) -> URL {
        transcriptURL(root: root, agentId: agentId, conversationId: conversationId)
            .appendingPathExtension("lock")
    }

    static func engineArtifactsDirectory(root: URL, conversationId: UUID) -> URL {
        root.appendingPathComponent("cache/engine-artifacts/\(conversationId.uuidString)", isDirectory: true)
    }

    static func dedupeStoreURL(root: URL) -> URL {
        root.appendingPathComponent("cache/dedupe.sqlite", isDirectory: false)
    }

    /// Optional auth profile metadata (`SAH_SESSION_AUTH_PROFILE`); not authoritative for credentials.
    static func authProfilesURL(root: URL) -> URL {
        root.appendingPathComponent("auth-profiles.json", isDirectory: false)
    }

    /// Redundant recovery index (conversation ids + catalog checksum) for tooling after partial store damage.
    static func sessionsRecoveryIndexURL(root: URL) -> URL {
        root.appendingPathComponent("sessions.json", isDirectory: false)
    }

    static func cronRunsDirectory(root: URL) -> URL {
        root.appendingPathComponent("cron/runs", isDirectory: true)
    }

    static func cronRunFileURL(root: URL, jobId: String) -> URL {
        cronRunsDirectory(root: root).appendingPathComponent("\(jobId).jsonl", isDirectory: false)
    }

    static func mediaRootDirectory(root: URL) -> URL {
        root.appendingPathComponent("media", isDirectory: true)
    }

    static func durableBlobsDirectory(root: URL) -> URL {
        mediaRootDirectory(root: root).appendingPathComponent("blobs", isDirectory: true)
    }

    static func durableBlobFileURL(root: URL, hashPrefix: String, blobId: String) -> URL {
        durableBlobsDirectory(root: root)
            .appendingPathComponent(hashPrefix, isDirectory: true)
            .appendingPathComponent(blobId, isDirectory: false)
    }

    static func durableTrashDirectory(root: URL) -> URL {
        mediaRootDirectory(root: root).appendingPathComponent(".trash", isDirectory: true)
    }

    static func durableTrashFileURL(root: URL, blobId: String) -> URL {
        durableTrashDirectory(root: root).appendingPathComponent(blobId, isDirectory: false)
    }

    static func ephemeralMediaDirectory(root: URL, lane: SessionBlobEphemeralLane) -> URL {
        mediaRootDirectory(root: root).appendingPathComponent(lane.rawValue, isDirectory: true)
    }

    static func ephemeralBlobFileURL(root: URL, lane: SessionBlobEphemeralLane, blobId: String) -> URL {
        ephemeralMediaDirectory(root: root, lane: lane).appendingPathComponent(blobId, isDirectory: false)
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func ensureSecureMediaDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
