//
//  Environment-driven session store root.
//

import Foundation

public enum SessionPersistenceConfiguration {
    /// When set, enables on-disk harness layout at this directory (see ``SessionPersistenceInstall``).
    public static var sessionStoreRoot: URL? {
        guard let raw = HarnessEnvironmentOverride.string("SAH_SESSION_STORE_ROOT"), !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    /// Per-process harness agent id (transcript subdirectory + catalog scope). Default `default`.
    public static var sessionAgentId: String {
        let raw = HarnessEnvironmentOverride.string("SAH_SESSION_AGENT_ID") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return SessionPersistenceLayout.defaultAgentId }
        return trimmed
    }

    /// Optional auth profile label persisted beside the store for recovery UX (not secret storage).
    static var sessionAuthProfileLabel: String? {
        let raw = HarnessEnvironmentOverride.string("SAH_SESSION_AUTH_PROFILE") ?? ""
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// SQLite `busy_timeout` in milliseconds for `catalog.sqlite` (and recommended for other session SQLite files). Default 5000; set `0` to rely on application retries only.
    static var sqliteBusyTimeoutMilliseconds: Int {
        let raw = HarnessEnvironmentOverride.string("SAH_SESSION_SQLITE_BUSY_TIMEOUT_MS") ?? ""
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 5000 }
        if let v = Int(t), v >= 0 { return v }
        return 5000
    }

    /// True when ``SAH_SESSION_STORE_ROOT`` is set (install wires ``LocalHarnessSessionPersistence``).
    public static var harnessOnDiskV2Configured: Bool {
        sessionStoreRoot != nil
    }

    /// Max blob bytes (spec default 5MB). Env: `SAH_SESSION_BLOB_MAX_BYTES`.
    static var blobMaxBytes: Int {
        parsePositiveIntEnv("SAH_SESSION_BLOB_MAX_BYTES", default: 5_242_880)
    }

    /// Default ephemeral TTL seconds (spec ~2 min). Env: `SAH_SESSION_BLOB_EPHEMERAL_TTL_SECONDS`.
    static var blobDefaultEphemeralTTLSeconds: Int {
        parsePositiveIntEnv("SAH_SESSION_BLOB_EPHEMERAL_TTL_SECONDS", default: 120)
    }

    /// When `1`, sweep expired inbound/outbound blobs at harness install. Env: `SAH_SESSION_BLOB_SWEEP_ON_STARTUP`.
    static var blobSweepOnStartup: Bool {
        HarnessEnvironmentOverride.string("SAH_SESSION_BLOB_SWEEP_ON_STARTUP") != "0"
    }

    /// When `1`, reclaim unreferenced durable blobs at harness install. Env: `SAH_SESSION_BLOB_RECLAIM_ON_STARTUP`.
    static var blobReclaimOnStartup: Bool {
        HarnessEnvironmentOverride.string("SAH_SESSION_BLOB_RECLAIM_ON_STARTUP") != "0"
    }

    /// Trash retention before hard-deleting unreferenced durable blobs. Env: `SAH_SESSION_BLOB_RECLAIM_GRACE_SECONDS`.
    /// Measured from `trashedAt` (when the blob entered `media/.trash/`), not blob byte age.
    static var blobReclaimGraceSeconds: Int {
        parsePositiveIntEnv("SAH_SESSION_BLOB_RECLAIM_GRACE_SECONDS", default: 3600)
    }

    /// When not `0`, verify/repair/quarantine transcripts at conversation startup. Env: `SAH_SESSION_TRANSCRIPT_VERIFY_ON_STARTUP`.
    static var transcriptVerifyOnStartup: Bool {
        HarnessEnvironmentOverride.string("SAH_SESSION_TRANSCRIPT_VERIFY_ON_STARTUP") != "0"
    }

    /// Periodic transcript integrity sweep for post-boot corruption. Env: `SAH_SESSION_TRANSCRIPT_VERIFY_PERIODIC`.
    public static var transcriptVerifyPeriodicEnabled: Bool {
        HarnessEnvironmentOverride.string("SAH_SESSION_TRANSCRIPT_VERIFY_PERIODIC") != "0"
    }

    /// Interval between periodic transcript integrity sweeps. Env: `SAH_SESSION_TRANSCRIPT_VERIFY_INTERVAL_SECONDS`.
    public static var transcriptVerifyPeriodicIntervalSeconds: Int {
        parsePositiveIntEnv("SAH_SESSION_TRANSCRIPT_VERIFY_INTERVAL_SECONDS", default: 3600)
    }

    // MARK: - Transcript file lock (README `acquire_write_lock`; Gap 10)
    //
    // Production default: one server process per SAH_SESSION_STORE_ROOT (single-writer via
    // ConversationPersistenceDomain actor). File locks defend multi-process writers (CLI + server).
    // See Sources/SwiftAgentHarness/Backends/Persistence/README.md (X4).

    /// Max wait for `flock` (`timeout_ms` on harness Protocol). Env: `SAH_TRANSCRIPT_LOCK_TIMEOUT_MS`.
    static var transcriptLockAcquireTimeoutMs: Int {
        parsePositiveIntEnv("SAH_TRANSCRIPT_LOCK_TIMEOUT_MS", default: 30_000)
    }

    /// Watchdog check interval while blocked on acquire (README ~60s). Env: `SAH_TRANSCRIPT_LOCK_WATCHDOG_INTERVAL_MS`.
    static var transcriptLockWatchdogIntervalMs: Int {
        parsePositiveIntEnv("SAH_TRANSCRIPT_LOCK_WATCHDOG_INTERVAL_MS", default: 60_000)
    }

    /// Max hold before forced reap attempt on acquire path (README ~5 min). Env: `SAH_TRANSCRIPT_LOCK_MAX_HOLD_MS`.
    static var transcriptLockMaxHoldMs: Int {
        parsePositiveIntEnv("SAH_TRANSCRIPT_LOCK_MAX_HOLD_MS", default: 300_000)
    }

    /// Grace after max-hold before reap. Env: `SAH_TRANSCRIPT_LOCK_MAX_HOLD_GRACE_MS`.
    static var transcriptLockMaxHoldGraceMs: Int {
        parsePositiveIntEnv("SAH_TRANSCRIPT_LOCK_MAX_HOLD_GRACE_MS", default: 30_000)
    }

    /// When `1`, append paths require the process-aware transcript lock on the current thread (Gap 11 / README `LockNotHeld`).
    static var enforceTranscriptWriteLock: Bool {
        HarnessEnvironmentOverride.string("SAH_SESSION_ENFORCE_TRANSCRIPT_LOCK") == "1"
    }

    // MARK: - Transcript subscribe strategy (README `subscribe`)

    /// Selects transcript subscribe tail strategy.
    /// - `polling`: force in-process polling
    /// - `multi_host`: multi-host seam (currently falls back to polling if no broker/watch adapter is configured)
    /// - default/unknown: `polling`
    static var transcriptSubscribeTailStrategy: TranscriptSubscribeTailStrategyKind {
        let raw = (HarnessEnvironmentOverride.string("SAH_TRANSCRIPT_SUBSCRIBE_STRATEGY") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "multi_host", "multihost", "broker":
            return .multiHost
        default:
            return .polling
        }
    }

    // MARK: - Lite recovery (Gap 12)

    /// Max bytes read from **start** and **end** of `sessions.json` when full JSON decode fails (README-style bounded scan). Env: `SAH_SESSION_LITE_RECOVERY_SCAN_BYTES`. Clamped **1024 … 2_097_152**; default **65536**.
    static var liteRecoveryScanBytes: Int {
        let raw = HarnessEnvironmentOverride.string("SAH_SESSION_LITE_RECOVERY_SCAN_BYTES") ?? ""
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Int
        if t.isEmpty {
            parsed = 65_536
        } else if let v = Int(t), v > 0 {
            parsed = v
        } else {
            parsed = 65_536
        }
        return min(2_097_152, max(1024, parsed))
    }

    /// First-line peek for JSONL header validation (bytes). Internal default for ``SessionPersistenceLiteRecovery``.
    static let liteRecoveryJsonlHeaderPeekBytes = 16_384

    private static func parsePositiveIntEnv(_ key: String, default def: Int) -> Int {
        let raw = HarnessEnvironmentOverride.string(key) ?? ""
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return def }
        if let v = Int(t), v > 0 { return v }
        return def
    }
}
