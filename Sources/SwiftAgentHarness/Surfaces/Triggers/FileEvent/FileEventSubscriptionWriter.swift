import Foundation

/// The two payload kinds that are *configuration* rather than queue events.
///
/// A separate type from `FileEventKind` so `.immediate` is unrepresentable here. When this took
/// `FileEventKind`, both the writer and the id helper needed a third branch that could only be a
/// mistake — the writer threw a mislabelled error, and the helper returned a bare, unprefixed
/// basename, which is exactly the drift the helper exists to prevent.
enum FileEventSubscriptionKind: Sendable, Equatable {
    case periodic
    case oneShot

    var payloadKind: FileEventKind {
        switch self {
        case .periodic: return .periodic
        case .oneShot: return .oneShot
        }
    }
}

/// Errors from writing a *subscription* file — the configuration half of the events directory.
///
/// Every case is something that would otherwise go wrong *later*, silently: the sync logs a
/// rejection and moves on, leaving the file on disk to fail again on the next scan, while the caller
/// has already been handed a task id for a task that does not exist.
enum FileEventSubscriptionError: Error, Equatable {
    /// A basename that would not survive the round trip: it must be usable as a filename, must not
    /// escape the events directory, and must not start with `.` (the queue skips dotfiles, so such a
    /// subscription would be written and then never seen).
    case invalidBasename(String)
    /// The events directory already holds a file for this basename that this write would destroy —
    /// a queued `immediate`, a subscription of the other kind, or (on a case-insensitive filesystem)
    /// the same file under a different spelling, which would register under an id this call does not
    /// return.
    case basenameInUse(String)
    /// A `periodic` subscription whose cron expression does not parse.
    case invalidSchedule(String)
    /// A `one-shot` whose `at` is not ISO-8601.
    case invalidTimestamp(String)
    /// A `one-shot` whose `at` is in the past, or too near to survive the trip to the watcher.
    case timestampTooSoon(String)
    /// A timezone identifier `TimeZone(identifier:)` does not recognise. Mirrors the registration
    /// validator's `unknownTimezone`, which would otherwise reject this file on every scan.
    case unknownTimezone(String)
    /// A timezone on a `one-shot`. The `at` string carries its own offset, so there is nothing for a
    /// zone to interpret and the registration validator drops it — accepting one would be a field
    /// that looks honoured and is not.
    case timezoneNotApplicable(String)
    /// Whitespace-only prompt text. `ScheduledTaskCreateScanner` refuses it downstream.
    case emptyText
    /// Prompt text `ProjectInstructionContentScanner` flags. The registration validator refuses this
    /// too, but only after the file is already on disk.
    case contentRefused([String])
    /// A partial correlation. `TriggerCorrelation.fromPayload` honours payload lineage only when
    /// `rootId` *and* `correlationId` are both present; anything less is discarded without a word,
    /// so a caller stitching a chain would get a broken one and no signal.
    case invalidCorrelation
    /// The payload file could not be removed, so the task it registered is still registered.
    case removalFailed(String)
}

extension FileEventQueueWriter {
    /// How far in the future a `one-shot` must be dated.
    ///
    /// Not cosmetic. `syncFutureOneShot` re-checks `atDate > Date()` when the watcher gets around to
    /// the file; a payload that was future at write time and past by then is not registered at all —
    /// it falls through to the immediate-consume path, which fires the turn *at once*, deletes the
    /// file, and skips the content scan that only runs on the registration path. The floor has to
    /// clear watcher notice plus a boot rescan, not just process latency.
    static var minimumOneShotLeadSeconds: TimeInterval { 60 }

    /// Write a `periodic` or `one-shot` subscription into the events directory.
    ///
    /// The events directory has two roles — an event *queue*, where a dropped `immediate` file *is*
    /// a trigger, consumed and deleted; and a *configuration store*, where a `periodic` or
    /// `one-shot` file registers a scheduled task and unregisters it when deleted. Only the queue
    /// half had a writer, so the harness could produce its own immediates but not its own
    /// subscriptions: those had to come from outside, and nothing could round-trip what it wrote.
    ///
    /// Writing is all this does. Registration happens when the watcher notices the file and
    /// `FileEventPeriodicSync` / `FileEventScheduledSync` route it through
    /// `TriggerRegistrationService` — deliberately, so a file written here and a file dropped by
    /// hand take exactly the same path to becoming a task.
    ///
    /// Every field the registration path can reject is validated *here*, before the first byte is
    /// written, so the returned id always names a task that will actually exist.
    ///
    /// `trust` is a *request*, not an assertion. It is written to the sidecar, read back by
    /// `FileEventTrustResolver`, and clamped to the creator's ceiling by the registration validator
    /// under `RegistrationAuthority.localFileDrop()` — this call cannot amplify trust, only ask for
    /// it.
    ///
    /// - Returns: the scheduled-task id the sync will register this file under.
    @discardableResult
    static func writeSubscription(
        eventsDirectory: URL,
        basename: String,
        kind: FileEventSubscriptionKind,
        text: String,
        schedule: String? = nil,
        at: String? = nil,
        timezone: String? = nil,
        conversationID: String? = nil,
        rootId: String? = nil,
        parentTriggerId: String? = nil,
        correlationId: String? = nil,
        trust: FileEventTrustSidecar,
        recordWritePhase: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        guard TriggerSlug.isValid(basename) else {
            throw FileEventSubscriptionError.invalidBasename(basename)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileEventSubscriptionError.emptyText
        }
        // The same scan `ScheduledTaskCreateScanner` runs. Without it this is the one rejection the
        // writer does not mirror: the file lands, an id comes back, and every scan from then on logs
        // `file_event_periodic_rejected` and moves on.
        let scan = ProjectInstructionContentScanner.scan(text)
        guard scan.isClean else {
            throw FileEventSubscriptionError.contentRefused(scan.matchedThreatIDs)
        }
        if rootId != nil || parentTriggerId != nil || correlationId != nil {
            guard rootId != nil, correlationId != nil else {
                throw FileEventSubscriptionError.invalidCorrelation
            }
        }
        let payload: FileEventPayload
        switch kind {
        case .periodic:
            guard let schedule, !schedule.isEmpty, (try? CronSchedule(expression: schedule)) != nil else {
                throw FileEventSubscriptionError.invalidSchedule(schedule ?? "")
            }
            if let timezone, !timezone.isEmpty, TimeZone(identifier: timezone) == nil {
                throw FileEventSubscriptionError.unknownTimezone(timezone)
            }
            payload = FileEventPayload(
                type: kind.payloadKind,
                text: text,
                at: nil,
                schedule: schedule,
                timezone: timezone,
                conversationID: conversationID,
                rootId: rootId,
                parentTriggerId: parentTriggerId,
                correlationId: correlationId
            )
        case .oneShot:
            if let timezone, !timezone.isEmpty {
                throw FileEventSubscriptionError.timezoneNotApplicable(timezone)
            }
            guard let at, let date = ISO8601DateFormatter().date(from: at) else {
                throw FileEventSubscriptionError.invalidTimestamp(at ?? "")
            }
            // Deliberately not injectable. A `now:` seam here could only be used to make a stale
            // timestamp look future, and the cases worth testing (a past `at`, an imminent one) are
            // reachable with the real clock.
            guard date > Date().addingTimeInterval(minimumOneShotLeadSeconds) else {
                throw FileEventSubscriptionError.timestampTooSoon(at)
            }
            payload = FileEventPayload(
                type: kind.payloadKind,
                text: text,
                at: at,
                schedule: nil,
                timezone: nil,
                conversationID: conversationID,
                rootId: rootId,
                parentTriggerId: parentTriggerId,
                correlationId: correlationId
            )
        }

        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try assertBasenameAvailable(eventsDirectory: eventsDirectory, basename: basename, kind: kind)
        let jsonURL = subscriptionURL(eventsDirectory: eventsDirectory, basename: basename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Trust sidecar first, then the payload — the same ordering `writeImmediate` uses, and for
        // the same reason: the watcher fires on the `.json`, so a sidecar written second can be
        // missed and the event resolved at the default `unknown-party`.
        let trustURL = FileEventQueueLayout.trustSidecarURL(for: jsonURL)
        recordWritePhase?("trust")
        try encoder.encode(trust).write(to: trustURL, options: .atomic)
        recordWritePhase?("json")
        do {
            try encoder.encode(payload).write(to: jsonURL, options: .atomic)
        } catch {
            // `.atomic` makes each file individually untearable and does nothing for the pair. A
            // sidecar left without its payload is inert to the queue but not harmless: the next file
            // dropped under this basename — by hand, by anyone — would inherit a trust claim it
            // never made. Dropping it can only attenuate (an overwrite falls back to
            // `unknown-party`), which is the safe direction.
            try? FileManager.default.removeItem(at: trustURL)
            throw error
        }
        recordWritePhase?("done")
        return FileEventQueueLayout.taskID(forSubscription: basename, kind: kind)
    }

    /// Remove a subscription and its sidecar. Deleting the file is what unregisters the task, so
    /// this is the write half's counterpart to `removeForDeletedFile`.
    ///
    /// Throws if the payload is present and cannot be removed. Reporting success there would tell
    /// the caller a subscription is gone while its task stays registered — and file deletion is the
    /// *only* thing that unregisters it. A file that is *already* gone is not that case: a
    /// concurrent removal, a user deleting it in Finder, and the consume path all reach the same end
    /// state, so those report `false`.
    ///
    /// The basename is validated on this path too. That does mean a hand-dropped `Daily.json` cannot
    /// be removed through this API; accepting an arbitrary string as a path component in order to
    /// delete it is the worse trade.
    ///
    /// - Returns: `true` when a subscription file was present and removed.
    @discardableResult
    static func removeSubscription(eventsDirectory: URL, basename: String) throws -> Bool {
        guard TriggerSlug.isValid(basename) else {
            throw FileEventSubscriptionError.invalidBasename(basename)
        }
        let jsonURL = subscriptionURL(eventsDirectory: eventsDirectory, basename: basename)
        let trustURL = FileEventQueueLayout.trustSidecarURL(for: jsonURL)
        var isDirectory: ObjCBool = false
        // The directory check is not pedantry: `removeItem` on a directory deletes it *and its
        // contents*, so `events/x.json/` would be recursively wiped by a call asking to unregister a
        // subscription.
        guard FileManager.default.fileExists(atPath: jsonURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            // Nothing registered, but a stray sidecar may still be sitting there.
            try? FileManager.default.removeItem(at: trustURL)
            return false
        }
        if let data = try? Data(contentsOf: jsonURL),
           let existing = try? JSONDecoder().decode(FileEventPayload.self, from: data),
           existing.type == .immediate {
            // A queued turn that has not fired yet, sharing the namespace. Deleting it here would
            // report "subscription removed" for a trigger that simply never happened.
            throw FileEventSubscriptionError.basenameInUse(basename)
        }
        // Payload first: while the sidecar outlives it the file is already invisible to the queue,
        // whereas the reverse order leaves a payload briefly resolvable at the default trust.
        do {
            try FileManager.default.removeItem(at: jsonURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            try? FileManager.default.removeItem(at: trustURL)
            return false
        } catch {
            throw FileEventSubscriptionError.removalFailed(basename)
        }
        // The sidecar is genuinely optional — a hand-dropped file may never have had one.
        try? FileManager.default.removeItem(at: trustURL)
        return true
    }

    /// Refuse a write that would destroy something else living under the same name.
    ///
    /// `writeImmediate` and `writeSubscription` compute the identical path, and both write
    /// `.atomic`, i.e. unconditional replace. Without this check, writing a subscription over a
    /// queued immediate silently drops a turn, and writing an immediate over a subscription gets the
    /// file consumed *and deleted* — which unregisters the scheduled task, because deletion is what
    /// unregistration means here.
    private static func assertBasenameAvailable(
        eventsDirectory: URL,
        basename: String,
        kind: FileEventSubscriptionKind
    ) throws {
        let target = "\(basename).\(FileEventQueueLayout.jsonExtension)"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: eventsDirectory.path)) ?? []
        for entry in entries where entry.lowercased() == target {
            // macOS is case-insensitive by default, so `Daily.json` *is* `daily.json` — but
            // `file-periodic:Daily` and `file-periodic:daily` are two different ids. Writing would
            // return an id the sync never registers.
            guard entry == target else {
                throw FileEventSubscriptionError.basenameInUse(basename)
            }
            guard let data = try? Data(contentsOf: eventsDirectory.appendingPathComponent(entry)),
                  let existing = try? JSONDecoder().decode(FileEventPayload.self, from: data) else {
                // Unreadable or not a payload at all. Overwriting is the same repair a hand-edit
                // would be, and refusing would strand the basename permanently.
                continue
            }
            guard existing.type == kind.payloadKind else {
                throw FileEventSubscriptionError.basenameInUse(basename)
            }
        }
    }

    private static func subscriptionURL(eventsDirectory: URL, basename: String) -> URL {
        eventsDirectory
            .appendingPathComponent(basename)
            .appendingPathExtension(FileEventQueueLayout.jsonExtension)
    }
}

extension FileEventQueueLayout {
    /// The scheduled-task id a subscription file registers under.
    ///
    /// The two prefixes were previously spelled at four call sites across the two sync types and the
    /// registration/removal paths; a writer that guessed differently would produce files that
    /// register one id and unregister another.
    static func taskID(forSubscription basename: String, kind: FileEventSubscriptionKind) -> String {
        switch kind {
        case .periodic: return periodicTaskIDPrefix + basename
        case .oneShot: return FileEventScheduledFileKind.oneShotTaskIDPrefix + basename
        }
    }
}
