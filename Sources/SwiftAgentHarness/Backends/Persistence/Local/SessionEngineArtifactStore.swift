//
//  Opaque engine-artifact blobs under `cache/engine-artifacts/<conversationId>/`.
//  Regenerable cache only — not transcript-authoritative; on v2 roots use ``HarnessSessionPersistence`` artifact methods when persisting derived engine blobs.
//

import Foundation

struct SessionEngineArtifactStore: Sendable {
    let root: URL

    func put(conversationId: UUID, key: String, data: Data) throws {
        let dir = SessionPersistenceLayout.engineArtifactsDirectory(root: root, conversationId: conversationId)
        try SessionPersistenceLayout.ensureDirectory(dir)
        let url = dir.appendingPathComponent(key, isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    func get(conversationId: UUID, key: String) -> Data? {
        let url = SessionPersistenceLayout.engineArtifactsDirectory(root: root, conversationId: conversationId)
            .appendingPathComponent(key, isDirectory: false)
        return try? Data(contentsOf: url)
    }

    func evict(conversationId: UUID, key: String?) throws {
        let dir = SessionPersistenceLayout.engineArtifactsDirectory(root: root, conversationId: conversationId)
        if let key {
            let url = dir.appendingPathComponent(key, isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        } else {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
