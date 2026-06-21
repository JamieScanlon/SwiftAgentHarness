//
//  Content-addressed media store: durable `media/blobs/` + ephemeral inbound/outbound lanes.
//

import CryptoKit
import Foundation

enum SessionBlobDurability: String, Sendable, Equatable, Codable {
    case durable
    case ephemeral
}

enum SessionBlobEphemeralLane: String, Sendable, Equatable, Codable {
    case inbound
    case outbound
}

struct SessionBlobRef: Sendable, Equatable, Codable {
    var id: String
    var mimeType: String
    var size: Int
    var originalName: String?
    var durability: SessionBlobDurability
    var trust: String
    var createdAt: Date
    var expiresAt: Date?
}

struct SessionBlobReclaimCounts: Sendable, Equatable {
    var trashed: Int
    var hardDeleted: Int
}

private struct SessionBlobSidecar: Codable, Sendable, Equatable {
    var mimeType: String
    var originalName: String?
    var durability: SessionBlobDurability
    var trust: String
    var createdAt: Date
    var expiresAt: Date?
    var lane: SessionBlobEphemeralLane?
    var trashedAt: Date?
}

enum SessionBlobImageRef {
    static let scheme = "blob://"

    static func path(for blobId: String) -> String { scheme + blobId.lowercased() }

    static func parsePath(_ path: String?) -> String? {
        guard let path, path.hasPrefix(scheme) else { return nil }
        let id = String(path.dropFirst(scheme.count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count == 64 else { return nil }
        return id
    }
}

struct SessionBlobStore: Sendable {
    let root: URL
    let maxBytes: Int

    func put(
        data: Data,
        durability: SessionBlobDurability,
        originalName: String? = nil,
        mimeTypeHint: String? = nil,
        trust: String = "user-direct",
        ttlSeconds: Int? = nil,
        lane: SessionBlobEphemeralLane = .inbound,
        now: Date = Date()
    ) throws -> SessionBlobRef {
        guard !data.isEmpty else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob data empty")
        }
        guard data.count <= maxBytes else {
            throw SessionPersistenceError.blobTooLarge(size: data.count, maxBytes: maxBytes)
        }
        if durability == .ephemeral, ttlSeconds == nil {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "ephemeral blob requires ttlSeconds")
        }
        let blobId = Self.sha256Hex(data)
        let mime = SessionBlobMIME.sniff(data: data, hint: mimeTypeHint)
        let expiresAt: Date?
        if durability == .ephemeral, let ttlSeconds {
            expiresAt = now.addingTimeInterval(TimeInterval(ttlSeconds))
        } else {
            expiresAt = nil
        }
        let sidecar = SessionBlobSidecar(
            mimeType: mime,
            originalName: originalName,
            durability: durability,
            trust: trust,
            createdAt: now,
            expiresAt: expiresAt,
            lane: durability == .ephemeral ? lane : nil,
            trashedAt: nil
        )
        switch durability {
        case .durable:
            let fileURL = try durableFileURL(blobId: blobId)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                break
            } else if isInTrash(blobId: blobId) {
                try resurrectDurableFromTrash(blobId: blobId)
            } else {
                try SessionPersistenceLayout.ensureSecureMediaDirectory(fileURL.deletingLastPathComponent())
                try SessionPersistenceLayout.ensureSecureMediaDirectory(SessionPersistenceLayout.mediaRootDirectory(root: root))
                try writeBlob(data: data, to: fileURL)
                try writeSidecar(sidecar, nextTo: fileURL)
            }
        case .ephemeral:
            let fileURL = try ephemeralFileURL(blobId: blobId, lane: lane)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try SessionPersistenceLayout.ensureSecureMediaDirectory(SessionPersistenceLayout.mediaRootDirectory(root: root))
                try SessionPersistenceLayout.ensureSecureMediaDirectory(fileURL.deletingLastPathComponent())
                try writeBlob(data: data, to: fileURL)
                try writeSidecar(sidecar, nextTo: fileURL)
            }
        }
        return SessionBlobRef(
            id: blobId,
            mimeType: mime,
            size: data.count,
            originalName: originalName,
            durability: durability,
            trust: trust,
            createdAt: now,
            expiresAt: expiresAt
        )
    }

    func get(blobId: String, now: Date = Date(), ignoreExpiry: Bool = false) throws -> Data {
        let normalized = Self.normalizeBlobId(blobId)
        let location = try resolveDurableOrEphemeralLocation(blobId: normalized, resurrectTrashed: true)
        guard let location else {
            throw SessionPersistenceError.blobNotFound(blobId: normalized)
        }
        if !ignoreExpiry,
           let sidecar = try readSidecar(nextTo: location.fileURL),
           let expiresAt = sidecar.expiresAt,
           now >= expiresAt {
            throw SessionPersistenceError.blobExpired(blobId: normalized, expiredAt: expiresAt)
        }
        return try Data(contentsOf: location.fileURL)
    }

    func stat(blobId: String, now: Date = Date()) throws -> SessionBlobRef {
        let normalized = Self.normalizeBlobId(blobId)
        let location = try resolveDurableOrEphemeralLocation(blobId: normalized, resurrectTrashed: true)
        guard let location else {
            throw SessionPersistenceError.blobNotFound(blobId: normalized)
        }
        let sidecar = try readSidecar(nextTo: location.fileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: location.fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if let expiresAt = sidecar?.expiresAt, now >= expiresAt {
            throw SessionPersistenceError.blobExpired(blobId: normalized, expiredAt: expiresAt)
        }
        return SessionBlobRef(
            id: normalized,
            mimeType: sidecar?.mimeType ?? "application/octet-stream",
            size: size,
            originalName: sidecar?.originalName,
            durability: sidecar?.durability ?? (location.isDurable ? .durable : .ephemeral),
            trust: sidecar?.trust ?? "user-direct",
            createdAt: sidecar?.createdAt ?? (attrs[.creationDate] as? Date ?? Date()),
            expiresAt: sidecar?.expiresAt
        )
    }

    func blobPath(blobId: String, now: Date = Date()) throws -> URL? {
        let normalized = Self.normalizeBlobId(blobId)
        let location = try resolveDurableOrEphemeralLocation(blobId: normalized, resurrectTrashed: true)
        guard let location else { return nil }
        if let sidecar = try readSidecar(nextTo: location.fileURL),
           let expiresAt = sidecar.expiresAt,
           now >= expiresAt {
            throw SessionPersistenceError.blobExpired(blobId: normalized, expiredAt: expiresAt)
        }
        return location.fileURL
    }

    func promote(blobId: String, now: Date = Date()) throws -> SessionBlobRef {
        let normalized = Self.normalizeBlobId(blobId)
        guard let location = try resolveLocation(blobId: normalized), !location.isDurable else {
            return try stat(blobId: normalized, now: now)
        }
        let data = try get(blobId: normalized, now: now, ignoreExpiry: true)
        var sidecar = try readSidecar(nextTo: location.fileURL) ?? SessionBlobSidecar(
            mimeType: SessionBlobMIME.sniff(data: data, hint: nil),
            originalName: nil,
            durability: .ephemeral,
            trust: "unknown-party",
            createdAt: now,
            expiresAt: nil,
            lane: location.lane,
            trashedAt: nil
        )
        let durableURL = try durableFileURL(blobId: normalized)
        try SessionPersistenceLayout.ensureSecureMediaDirectory(durableURL.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: durableURL.path) {
            if isInTrash(blobId: normalized) {
                try resurrectDurableFromTrash(blobId: normalized)
            } else {
                try writeBlob(data: data, to: durableURL)
            }
        }
        sidecar.durability = .durable
        sidecar.expiresAt = nil
        sidecar.lane = nil
        sidecar.trashedAt = nil
        try writeSidecar(sidecar, nextTo: durableURL)
        try? FileManager.default.removeItem(at: location.fileURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: location.fileURL))
        return try stat(blobId: normalized, now: now)
    }

    func delete(blobId: String) throws {
        let normalized = Self.normalizeBlobId(blobId)
        guard let location = try resolveLocation(blobId: normalized) else {
            throw SessionPersistenceError.blobNotFound(blobId: normalized)
        }
        try? FileManager.default.removeItem(at: location.fileURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: location.fileURL))
    }

    func sweepExpired(now: Date = Date()) throws -> Int {
        var removed = 0
        for lane in [SessionBlobEphemeralLane.inbound, SessionBlobEphemeralLane.outbound] {
            let dir = SessionPersistenceLayout.ephemeralMediaDirectory(root: root, lane: lane)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension.isEmpty {
                if let sidecar = try? readSidecar(nextTo: file),
                   let expiresAt = sidecar.expiresAt,
                   now >= expiresAt {
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.removeItem(at: sidecarURL(for: file))
                    removed += 1
                }
            }
        }
        return removed
    }

    func listDurableBlobIdsOnDisk() throws -> Set<String> {
        let dir = SessionPersistenceLayout.durableBlobsDirectory(root: root)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        var ids: Set<String> = []
        let prefixes = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for prefixDir in prefixes where prefixDir.hasDirectoryPath {
            let files = try FileManager.default.contentsOfDirectory(at: prefixDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension.isEmpty {
                let blobId = SessionBlobStore.normalizeBlobId(file.lastPathComponent)
                if Self.isValidBlobId(blobId) { ids.insert(blobId) }
            }
        }
        return ids
    }

    func markUnreferencedDurableForTrash(liveBlobIds: Set<String>, now: Date = Date()) throws -> Int {
        var trashed = 0
        let dir = SessionPersistenceLayout.durableBlobsDirectory(root: root)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        let prefixes = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for prefixDir in prefixes where prefixDir.hasDirectoryPath {
            let files = try FileManager.default.contentsOfDirectory(at: prefixDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension.isEmpty {
                let blobId = SessionBlobStore.normalizeBlobId(file.lastPathComponent)
                guard Self.isValidBlobId(blobId) else { continue }
                if liveBlobIds.contains(blobId) { continue }
                if isInTrash(blobId: blobId) { continue }
                let sidecar = try readSidecar(nextTo: file) ?? SessionBlobSidecar(
                    mimeType: "application/octet-stream",
                    originalName: nil,
                    durability: .durable,
                    trust: "unknown-party",
                    createdAt: now,
                    expiresAt: nil,
                    lane: nil,
                    trashedAt: nil
                )
                try moveDurableToTrash(blobId: blobId, liveFileURL: file, sidecar: sidecar, now: now)
                trashed += 1
            }
        }
        return trashed
    }

    func hardDeleteExpiredTrash(
        liveBlobIds: Set<String>,
        retentionInterval: TimeInterval,
        now: Date = Date()
    ) throws -> Int {
        var removed = 0
        let trashDir = SessionPersistenceLayout.durableTrashDirectory(root: root)
        guard FileManager.default.fileExists(atPath: trashDir.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension.isEmpty {
            let blobId = SessionBlobStore.normalizeBlobId(file.lastPathComponent)
            guard Self.isValidBlobId(blobId) else { continue }
            let sidecar = try readSidecar(nextTo: file)
            let trashedAt = sidecar?.trashedAt ?? (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? now
            guard now.timeIntervalSince(trashedAt) >= retentionInterval else { continue }
            guard !liveBlobIds.contains(blobId) else { continue }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: sidecarURL(for: file))
            removed += 1
        }
        return removed
    }

    func reclaimUnreferencedDurable(
        liveBlobIds: Set<String>,
        trashRetentionInterval: TimeInterval,
        now: Date = Date()
    ) throws -> SessionBlobReclaimCounts {
        let trashed = try markUnreferencedDurableForTrash(liveBlobIds: liveBlobIds, now: now)
        let hardDeleted = try hardDeleteExpiredTrash(
            liveBlobIds: liveBlobIds,
            retentionInterval: trashRetentionInterval,
            now: now
        )
        return SessionBlobReclaimCounts(trashed: trashed, hardDeleted: hardDeleted)
    }

    func putFromURL(
        url: URL,
        durability: SessionBlobDurability = .ephemeral,
        trust: String = "unknown-party",
        ttlSeconds: Int? = nil,
        maxBytes: Int? = nil,
        lane: SessionBlobEphemeralLane = .inbound,
        resolver: any SessionBlobHostResolving = SessionBlobSystemHostResolver()
    ) throws -> SessionBlobRef {
        let cap = maxBytes ?? self.maxBytes
        let data = try SessionBlobURLFetchGuard.fetchData(url: url, maxBytes: cap, resolver: resolver)
        return try put(
            data: data,
            durability: durability,
            originalName: url.lastPathComponent.isEmpty ? nil : url.lastPathComponent,
            mimeTypeHint: nil,
            trust: trust,
            ttlSeconds: ttlSeconds ?? SessionPersistenceConfiguration.blobDefaultEphemeralTTLSeconds,
            lane: lane
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    static func normalizeBlobId(_ blobId: String) -> String {
        blobId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidBlobId(_ blobId: String) -> Bool {
        blobId.count == 64 && blobId.allSatisfy { $0.isHexDigit }
    }

    /// True when durable bytes exist on disk in the live lane or in `.trash` (pending resurrection).
    static func durableFileExists(root: URL, blobId: String) -> Bool {
        let normalized = normalizeBlobId(blobId)
        guard isValidBlobId(normalized) else { return false }
        let prefix = String(normalized.prefix(2))
        let liveURL = SessionPersistenceLayout.durableBlobFileURL(root: root, hashPrefix: prefix, blobId: normalized)
        if FileManager.default.fileExists(atPath: liveURL.path) { return true }
        let trashURL = SessionPersistenceLayout.durableTrashFileURL(root: root, blobId: normalized)
        return FileManager.default.fileExists(atPath: trashURL.path)
    }

    private struct ResolvedLocation {
        var fileURL: URL
        var isDurable: Bool
        var isTrashed: Bool
        var lane: SessionBlobEphemeralLane?
    }

    private func resolveLocation(blobId: String) throws -> ResolvedLocation? {
        let durable = try durableFileURL(blobId: blobId)
        if FileManager.default.fileExists(atPath: durable.path) {
            return ResolvedLocation(fileURL: durable, isDurable: true, isTrashed: false, lane: nil)
        }
        let trash = trashFileURL(blobId: blobId)
        if FileManager.default.fileExists(atPath: trash.path) {
            return ResolvedLocation(fileURL: trash, isDurable: true, isTrashed: true, lane: nil)
        }
        for lane in [SessionBlobEphemeralLane.inbound, SessionBlobEphemeralLane.outbound] {
            let ephemeral = try ephemeralFileURL(blobId: blobId, lane: lane)
            if FileManager.default.fileExists(atPath: ephemeral.path) {
                return ResolvedLocation(fileURL: ephemeral, isDurable: false, isTrashed: false, lane: lane)
            }
        }
        return nil
    }

    private func resolveDurableOrEphemeralLocation(blobId: String, resurrectTrashed: Bool) throws -> ResolvedLocation? {
        guard var location = try resolveLocation(blobId: blobId) else { return nil }
        if resurrectTrashed, location.isTrashed {
            try resurrectDurableFromTrash(blobId: blobId)
            location = try resolveLocation(blobId: blobId) ?? location
        }
        return location
    }

    private func trashFileURL(blobId: String) -> URL {
        SessionPersistenceLayout.durableTrashFileURL(root: root, blobId: Self.normalizeBlobId(blobId))
    }

    private func isInTrash(blobId: String) -> Bool {
        FileManager.default.fileExists(atPath: trashFileURL(blobId: blobId).path)
    }

    private func moveDurableToTrash(blobId: String, liveFileURL: URL, sidecar: SessionBlobSidecar, now: Date) throws {
        var updated = sidecar
        updated.trashedAt = now
        let trashURL = trashFileURL(blobId: blobId)
        try SessionPersistenceLayout.ensureSecureMediaDirectory(SessionPersistenceLayout.durableTrashDirectory(root: root))
        try FileManager.default.moveItem(at: liveFileURL, to: trashURL)
        try writeSidecar(updated, nextTo: trashURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: liveFileURL))
    }

    private func resurrectDurableFromTrash(blobId: String) throws {
        let normalized = Self.normalizeBlobId(blobId)
        let trashURL = trashFileURL(blobId: normalized)
        guard FileManager.default.fileExists(atPath: trashURL.path) else { return }
        var sidecar = try readSidecar(nextTo: trashURL) ?? SessionBlobSidecar(
            mimeType: "application/octet-stream",
            originalName: nil,
            durability: .durable,
            trust: "unknown-party",
            createdAt: Date(),
            expiresAt: nil,
            lane: nil,
            trashedAt: nil
        )
        sidecar.trashedAt = nil
        let liveURL = try durableFileURL(blobId: normalized)
        try SessionPersistenceLayout.ensureSecureMediaDirectory(liveURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: liveURL.path) {
            try? FileManager.default.removeItem(at: trashURL)
            try? FileManager.default.removeItem(at: sidecarURL(for: trashURL))
            return
        }
        try FileManager.default.moveItem(at: trashURL, to: liveURL)
        try writeSidecar(sidecar, nextTo: liveURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: trashURL))
    }

    private func durableFileURL(blobId: String) throws -> URL {
        let normalized = Self.normalizeBlobId(blobId)
        guard normalized.count == 64 else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "invalid blob id")
        }
        let prefix = String(normalized.prefix(2))
        return SessionPersistenceLayout.durableBlobFileURL(root: root, hashPrefix: prefix, blobId: normalized)
    }

    private func ephemeralFileURL(blobId: String, lane: SessionBlobEphemeralLane) throws -> URL {
        let normalized = Self.normalizeBlobId(blobId)
        guard normalized.count == 64 else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "invalid blob id")
        }
        return SessionPersistenceLayout.ephemeralBlobFileURL(root: root, lane: lane, blobId: normalized)
    }

    private func sidecarURL(for blobFile: URL) -> URL {
        blobFile.appendingPathExtension("meta")
    }

    private func writeSidecar(_ sidecar: SessionBlobSidecar, nextTo blobFile: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(sidecar)
        try data.write(to: sidecarURL(for: blobFile), options: .atomic)
    }

    private func readSidecar(nextTo blobFile: URL) throws -> SessionBlobSidecar? {
        let url = sidecarURL(for: blobFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SessionBlobSidecar.self, from: Data(contentsOf: url))
    }

    private func writeBlob(data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }
}

enum SessionBlobMIME {
    static func sniff(data: Data, hint: String?) -> String {
        if let hint, !hint.isEmpty { return hint }
        guard data.count >= 4 else { return "application/octet-stream" }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "image/webp"
        }
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        return "application/octet-stream"
    }
}
