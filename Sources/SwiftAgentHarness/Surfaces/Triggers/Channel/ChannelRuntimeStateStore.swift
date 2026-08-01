import Foundation

/// One channel's runtime lifecycle overlay.
///
/// `disabled` is stored explicitly rather than inferred from absence so that "the owner turned this
/// off" and "nobody has ever touched this" are distinguishable — the first must survive a restart,
/// the second must not pin anything.
struct ChannelRuntimeStateEntry: Codable, Sendable, Equatable {
    var channel: String
    var disabled: Bool
    var updatedAtMs: Int64
    /// Who last changed it. Owner or installer only — the policy denies model-driven creators.
    var changedBy: RegistrationCreator?
    var reason: String?
}

/// The caller-safe projection of an overlay entry.
///
/// `changedBy` is dropped: `RegistrationCreator` carries conversation, lineage-root and owner-account
/// UUIDs, and a listing that handed those out would let one tenant enumerate another's. The audit
/// log is where the full attribution lives, behind the operator's own access controls.
struct ChannelRuntimeStateView: Sendable, Equatable {
    var channel: String
    var disabled: Bool
    var updatedAtMs: Int64
    /// Creator *class* only — "owner", "installer" — never the identity.
    var changedByLabel: String?
}

enum ChannelRuntimeStateError: Error, Equatable {
    /// The file exists and is non-empty but does not decode.
    case corruptRuntimeStateFile(path: String)
}

/// Persistent per-channel lifecycle overlay.
///
/// `channels.json` is operator config and is authoritative — the same rule the webhook path enforces
/// with `staticRouteImmutable`. Nothing at runtime rewrites it. This store is the separate, narrower
/// thing a runtime client *may* write: a record that a channel the operator permitted is currently
/// held off.
///
/// **The overlay can only attenuate.** The effective verdict is `configEnabled && !disabled`, so a
/// channel the operator set to `enabled: false` cannot be switched on from any runtime surface —
/// turning one on means editing config, which is the decision that carries the credentials and the
/// inbound socket. `enable` here means "clear a runtime disable", never "override the operator".
///
/// Same locking and atomic-write idiom as `ScheduledTaskStore` and `TriggerSpendLedgerStore`:
/// synchronous store, so `NSLock` rather than `Mutex`.
struct ChannelRuntimeStateStore: Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [String: ChannelRuntimeStateEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try readUnlocked().channels
    }

    /// Record a lifecycle decision. Returns the stored entry.
    ///
    /// Writing `enabled: true` stores `disabled: false` rather than removing the row, so the audit
    /// trail keeps "explicitly re-enabled at T by X" instead of losing it to a deletion.
    ///
    /// A file that will not decode is **quarantined**, not truncated: it is renamed aside and a
    /// fresh file is written carrying this decision. Refusing to write instead would let anyone who
    /// can scribble one byte into the file wedge the owner out of ever disabling a channel again —
    /// a corrupt file must not be a lock. Quarantine keeps the original bytes for inspection, makes
    /// the event loud, and leaves the owner's explicit decision in force. This is safe *because*
    /// reads never fall back to "no overlay" (see `ChannelListenerRegistry.runtimeEnabled`).
    @discardableResult
    func setDisabled(
        channel: ChannelId,
        disabled: Bool,
        changedBy: RegistrationCreator?,
        reason: String? = nil,
        now: Date = Date()
    ) throws -> ChannelRuntimeStateEntry {
        lock.lock()
        defer { lock.unlock() }
        var file: ChannelRuntimeStateFile
        do {
            file = try readUnlocked()
        } catch ChannelRuntimeStateError.corruptRuntimeStateFile {
            try quarantineUnlocked(now: now)
            file = ChannelRuntimeStateFile()
        }
        let entry = ChannelRuntimeStateEntry(
            channel: channel.rawValue,
            disabled: disabled,
            updatedAtMs: Int64(now.timeIntervalSince1970 * 1000),
            changedBy: changedBy,
            reason: reason
        )
        file.channels[channel.rawValue] = entry
        try writeUnlocked(file)
        return entry
    }

    struct ChannelRuntimeStateFile: Codable, Sendable, Equatable {
        var channels: [String: ChannelRuntimeStateEntry]

        init(channels: [String: ChannelRuntimeStateEntry] = [:]) {
            self.channels = channels
        }
    }

    private func quarantineUnlocked(now: Date) throws {
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        let destination = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
        try FileManager.default.moveItem(at: fileURL, to: destination)
    }

    private func readUnlocked() throws -> ChannelRuntimeStateFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ChannelRuntimeStateFile()
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return ChannelRuntimeStateFile() }
        guard let file = try? JSONDecoder().decode(ChannelRuntimeStateFile.self, from: data) else {
            throw ChannelRuntimeStateError.corruptRuntimeStateFile(path: fileURL.path)
        }
        return file
    }

    private func writeUnlocked(_ file: ChannelRuntimeStateFile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
