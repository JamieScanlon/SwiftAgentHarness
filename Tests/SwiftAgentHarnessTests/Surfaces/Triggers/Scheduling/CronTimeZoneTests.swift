import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Cron wall-clock timezones")
struct CronTimeZoneTests {
    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    /// A cron task carrying a zone, with the jitter-bearing `lastFiredAt` the rule compares against.
    private static func cronTask(
        expr: String,
        zone: String,
        lastFiredAt: Date?,
        createdAt: Date? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            id: "tz-\(UUID().uuidString)",
            createdAt: Int64((createdAt ?? Date()).timeIntervalSince1970 * 1000),
            lastFiredAt: lastFiredAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            schedule: ScheduledTaskSchedule(kind: .cron, expr: expr),
            payloadKind: .agentTurn,
            payloadText: "x",
            recurring: true,
            timezone: zone
        )
    }

    private static func makeScheduler() -> TriggerSchedulerService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tz-sched-\(UUID().uuidString)")
        return TriggerSchedulerService(
            store: ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json")),
            deliver: { _ in TriggerActivationResult(decision: .admitted, sessionID: nil) },
            lockURL: directory.appendingPathComponent("scheduler.lock"),
            logger: Logger(label: "test")
        )
    }

    private func components(_ date: Date, in zone: String) throws -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// The whole point: "09:00 daily" means 09:00 where the human is, not where the host is.
    @Test("a daily cron fires at the local hour, not the host hour")
    func firesAtLocalHour() throws {
        let cron = try CronSchedule(expression: "0 9 * * *")
        let zone = "Europe/Berlin"
        // 2026-03-02T00:00Z is 01:00 in Berlin (CET, UTC+1).
        let next = try #require(cron.nextDate(after: try date("2026-03-02T00:00:00Z"), in: TimeZone(identifier: zone)))
        let local = try components(next, in: zone)
        #expect(local.hour == 9)
        #expect(local.minute == 0)
        #expect(local.day == 2)
        // 09:00 CET is 08:00Z — the assertion that would fail if the zone were ignored.
        let utc = try components(next, in: "UTC")
        #expect(utc.hour == 8)
    }

    @Test("the same expression in two zones resolves to two different instants")
    func zonesDiverge() throws {
        let cron = try CronSchedule(expression: "0 9 * * *")
        let after = try date("2026-06-01T00:00:00Z")
        let berlin = try #require(cron.nextDate(after: after, in: TimeZone(identifier: "Europe/Berlin")))
        let losAngeles = try #require(cron.nextDate(after: after, in: TimeZone(identifier: "America/Los_Angeles")))
        #expect(berlin != losAngeles)
        // Berlin is ahead, so its 09:00 lands first.
        #expect(berlin < losAngeles)
    }

    /// `nil` keeps the pre-timezone behaviour rather than switching to UTC, because reinterpreting
    /// existing rows as UTC would move every recurring task by the deployment's offset.
    ///
    /// Compared against the *old* calendar-taking overload rather than against `TimeZone.current`:
    /// the latter passes on a UTC CI host even if the zone argument were ignored entirely, which is
    /// the bug this is meant to catch.
    @Test("a nil zone reproduces the pre-timezone calendar behaviour")
    func nilZoneIsProcessZone() throws {
        let cron = try CronSchedule(expression: "0 9 * * *")
        let after = try date("2026-06-01T00:00:00Z")
        let legacy = cron.nextDate(after: after, calendar: Calendar(identifier: .gregorian))
        #expect(cron.nextDate(after: after, in: nil) == legacy)
    }

    /// `nextDate` must never return an instant at or before its input. It could: the old start
    /// computation searched forward from the start of the local day with `repeatedTimePolicy`
    /// defaulting to `.first`, so inside a fall-back it resolved an hour *behind* the input.
    @Test("the result is always strictly after the input, including inside a repeated hour")
    func alwaysMovesForward() throws {
        let cron = try CronSchedule(expression: "30 * * * *")
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 09:30Z is 01:30 PST — the second of the two 01:30s on the fall-back day.
        let input = try date("2026-11-01T09:30:00Z")
        let next = try #require(cron.nextDate(after: input, in: zone))
        #expect(next > input)
    }

    // MARK: - Daylight saving

    /// Fall-back: 01:30 local happens twice in absolute time. A job pinned to an hour runs once —
    /// the rule Vixie cron uses, and what "01:30 daily" means to the person who wrote it.
    ///
    /// Driven through `TriggerSchedulerService.nextFireDate` rather than `CronSchedule` directly,
    /// because that is where the rule lives and where the previous fire is in scope. An earlier
    /// version put the check inside `CronSchedule.nextDate`, comparing against whatever reference it
    /// was handed — which for a recurring task is the scheduler *tick*, so it only bit in the one
    /// tick that happened to land on `:30`. A test that called `nextDate(after: previousFire)`
    /// passed anyway, because it fed in the reference production never uses.
    ///
    /// US DST ends 2026-11-01, when 02:00 PDT becomes 01:00 PST.
    @Test("an hour-pinned job does not fire twice through a fall-back")
    func fallBackDoesNotDoubleFire() async throws {
        let scheduler = Self.makeScheduler()
        let firstFire = try date("2026-11-01T08:30:00Z")  // 01:30 PDT
        let task = Self.cronTask(expr: "30 1 * * *", zone: "America/Los_Angeles", lastFiredAt: firstFire)

        // A tick inside the repeated hour, well past the boundary's wall-clock minute — the case the
        // previous implementation missed.
        let now = try date("2026-11-01T09:05:00Z")
        let notBefore = try date("2026-11-01T09:35:00Z")
        let next = try #require(await scheduler.nextFireDate(for: task, now: now))
        #expect(next > notBefore, "must not fire again at 01:30 PST (09:30Z)")
        let local = try components(next, in: "America/Los_Angeles")
        #expect(local.day == 2, "next fire belongs to the following day")
        #expect(local.hour == 1)
    }

    /// The suppression must not apply to a wildcard hour: `30 * * * *` is asking for every
    /// occurrence, and both 01:xx hours are real time that really elapsed.
    @Test("a wildcard-hour job still fires through the repeated hour")
    func fallBackKeepsWildcardHourFires() async throws {
        let scheduler = Self.makeScheduler()
        let firstFire = try date("2026-11-01T08:30:00Z")  // 01:30 PDT
        let task = Self.cronTask(expr: "30 * * * *", zone: "America/Los_Angeles", lastFiredAt: firstFire)

        let now = try date("2026-11-01T09:05:00Z")
        let expected = try date("2026-11-01T09:30:00Z")
        let next = try #require(await scheduler.nextFireDate(for: task, now: now))
        // 09:30Z is 01:30 PST — the repeated hour, and a fire this job is owed.
        #expect(abs(next.timeIntervalSince(expected)) < 30)
    }

    /// The rule keys off the previous fire, so a job that has never run through the transition is
    /// not suppressed. Without this, a harness that was down across 01:30 PDT would skip the day.
    @Test("a job that has not yet fired is not suppressed inside the repeated hour")
    func neverFiredJobIsNotSuppressed() async throws {
        let scheduler = Self.makeScheduler()
        // Created before the first 01:30 on the fall-back day so the owed fire is that boundary —
        // default `createdAt = now` would resolve months earlier and never exercise the rule.
        let createdAt = try date("2026-11-01T08:00:00Z")  // 01:00 PDT
        let task = Self.cronTask(
            expr: "30 1 * * *",
            zone: "America/Los_Angeles",
            lastFiredAt: nil,
            createdAt: createdAt
        )
        let now = try date("2026-11-01T09:05:00Z")
        let expected = try date("2026-11-01T08:30:00Z")  // 01:30 PDT
        let next = try #require(await scheduler.nextFireDate(for: task, now: now))
        let local = try components(next, in: "America/Los_Angeles")
        #expect(local.day == 1, "the 01:30 it never got should still run")
        #expect(local.hour == 1)
        // ±6s scheduler jitter can land in the adjacent minute; compare the instant instead.
        #expect(abs(next.timeIntervalSince(expected)) < 30)
    }

    /// Spring-forward: 02:30 local does not exist on the transition day, so the job is skipped that
    /// day and resumes the next. A documented divergence from Vixie, which would run it once at the
    /// new time — recorded as a test so the behaviour is deliberate rather than discovered.
    @Test("a job at a nonexistent local time is skipped for that day")
    func springForwardSkipsTheDay() throws {
        let cron = try CronSchedule(expression: "30 2 * * *")
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 2026-03-08: 02:00 PST jumps to 03:00 PDT, so 02:30 never occurs.
        let next = try #require(cron.nextDate(after: try date("2026-03-08T09:00:00Z"), in: zone))
        let local = try components(next, in: "America/Los_Angeles")
        #expect(local.day == 9, "02:30 does not exist on the 8th")
        #expect(local.hour == 2)
        #expect(local.minute == 30)
    }
}

@Suite("Schedule timezone registration")
struct ScheduleTimezoneRegistrationTests {
    private func makeService() -> (TriggerRegistrationService, ScheduledTaskStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tz-\(UUID().uuidString)")
            .appendingPathComponent("tasks.json")
        let store = ScheduledTaskStore(fileURL: url)
        return (TriggerRegistrationTestSupport.service(store: store), store)
    }

    private func cronSpec(timezone: String?) -> ScheduleRegistrationSpec {
        ScheduleRegistrationSpec(
            schedule: ScheduledTaskSchedule(kind: .cron, expr: "0 9 * * *"),
            payloadKind: .agentTurn,
            payloadText: "morning briefing",
            recurring: true,
            timezone: timezone
        )
    }

    @Test("an explicit zone is stored")
    func explicitZoneStored() throws {
        let (service, _) = makeService()
        let task = try service.registerSchedule(cronSpec(timezone: "Europe/Berlin"), authority: .installer)
        #expect(task.timezone == "Europe/Berlin")
        #expect(task.resolvedTimeZone == TimeZone(identifier: "Europe/Berlin"))
    }

    /// Stamped rather than left implicit: a row with no zone inherits whichever host it later runs
    /// on, which is how "every morning at 9" becomes 2am after a deploy.
    @Test("a cron create with no zone is stamped with the host zone")
    func hostZoneStamped() throws {
        let (service, _) = makeService()
        let task = try service.registerSchedule(cronSpec(timezone: nil), authority: .installer)
        #expect(task.timezone == TimeZone.current.identifier)
    }

    /// Defaulting an unrecognised identifier would produce a task that runs at the wrong hour,
    /// silently, forever. The registration failure is the only version a user can see and correct.
    @Test("an unrecognised identifier is refused, not defaulted")
    func unknownZoneRefused() throws {
        let (service, _) = makeService()
        #expect(throws: TriggerRegistrationError.validation(.unknownTimezone("Mars/Olympus_Mons"))) {
            try service.registerSchedule(cronSpec(timezone: "Mars/Olympus_Mons"), authority: .installer)
        }
    }

    /// `at` carries its own offset and `every` is a pure duration, so neither has a wall-clock to
    /// interpret and neither is stamped.
    @Test("non-cron schedules are not stamped")
    func nonCronNotStamped() throws {
        let (service, _) = makeService()
        let spec = ScheduleRegistrationSpec(
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 600_000),
            payloadKind: .agentTurn,
            payloadText: "poll",
            recurring: true
        )
        let task = try service.registerSchedule(spec, authority: .installer)
        #expect(task.timezone == nil)
    }

    /// An update re-derived from the caller would move an existing schedule the first time it is
    /// edited from a host in another zone — the same reasoning that makes attribution create-time.
    @Test("an update preserves the stored zone")
    func updatePreservesZone() throws {
        let (service, _) = makeService()
        let created = try service.registerSchedule(cronSpec(timezone: "Asia/Tokyo"), authority: .installer)
        let updated = try service.updateSchedule(id: created.id, authority: .installer) { spec in
            spec.payloadText = "changed"
        }
        #expect(updated.timezone == "Asia/Tokyo")
    }

    @Test("an update can change the zone explicitly")
    func updateCanChangeZone() throws {
        let (service, _) = makeService()
        let created = try service.registerSchedule(cronSpec(timezone: "Asia/Tokyo"), authority: .installer)
        let updated = try service.updateSchedule(id: created.id, authority: .installer) { spec in
            spec.timezone = "Europe/Lisbon"
        }
        #expect(updated.timezone == "Europe/Lisbon")
    }

    /// A row written before the field existed keeps the old behaviour rather than being
    /// reinterpreted as UTC, which would move every existing schedule by the host's offset.
    @Test("a legacy row with no zone decodes as nil")
    func legacyRowDecodesAsNil() throws {
        let json = #"""
        {"id":"legacy","createdAt":1,"schedule":{"kind":"cron","expr":"0 9 * * *"},
         "payloadKind":"agentTurn","payloadText":"x","delivery":"none","recurring":true,
         "permanent":false,"durable":true,"trust":"user-deferred","routingMode":"isolated","enabled":true}
        """#
        let task = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        #expect(task.timezone == nil)
        #expect(task.resolvedTimeZone == nil)
    }
}
