//
//  Best-effort `sessions.json` snapshot for catalog recovery (P3b).
//

import CryptoKit
import Foundation

enum SessionPersistenceRecoveryIndexWriter {
    private struct FilePayload: Encodable {
        var format: String
        var catalogSchemaVersion: Int
        var updatedAtEpoch: TimeInterval
        var agentId: String
        var authProfileLabel: String?
        var conversationIds: [String]
        /// Stable fingerprint of sorted ids + schema version (not a security guarantee).
        var conversationSetFingerprintSHA256: String
    }

    static func writeActiveAuthProfileHintIfNeeded(root: URL) throws {
        guard let label = SessionPersistenceConfiguration.sessionAuthProfileLabel else { return }
        try SessionPersistenceLayout.ensureDirectory(root)
        let url = SessionPersistenceLayout.authProfilesURL(root: root)
        let payload = ["activeProfileLabel": label]
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }

    static func writeSessionsRecoveryIndex(
        root: URL,
        agentId: String,
        authProfileLabel: String?,
        catalogSchemaVersion: Int,
        conversationIds: [UUID]
    ) throws {
        let sorted = conversationIds.map(\.uuidString).sorted()
        let fpInput = Data(
            "\(catalogSchemaVersion):\(sorted.joined(separator: ","))".utf8
        )
        let digest = SHA256.hash(data: fpInput)
        let fpHex = digest.map { String(format: "%02x", $0) }.joined()
        let body = FilePayload(
            format: "sah-sessions-recovery-v1",
            catalogSchemaVersion: catalogSchemaVersion,
            updatedAtEpoch: Date().timeIntervalSince1970,
            agentId: agentId,
            authProfileLabel: authProfileLabel,
            conversationIds: sorted,
            conversationSetFingerprintSHA256: fpHex
        )
        let data = try JSONEncoder().encode(body)
        let url = SessionPersistenceLayout.sessionsRecoveryIndexURL(root: root)
        try SessionPersistenceLayout.ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }
}
