import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("CronSchedule")
struct CronScheduleTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("parses standard five-field cron expression")
    func parsesCronExpression() throws {
        let schedule = try CronSchedule(expression: "*/5 * * * *")
        #expect(schedule.expression == "*/5 * * * *")
    }

    @Test("computes next run for every-five-minutes schedule")
    func nextDateEveryFiveMinutes() throws {
        let schedule = try CronSchedule(expression: "*/5 * * * *")
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let now = formatter.date(from: "2026-03-14T18:12:34Z")!
        let next = schedule.nextDate(after: now, calendar: utcCalendar)
        #expect(next == formatter.date(from: "2026-03-14T18:15:00Z"))
    }

    @Test("supports day-of-week with 0 or 7 as Sunday")
    func supportsSundayAliases() throws {
        let sundayWithZero = try CronSchedule(expression: "0 9 * * 0")
        let sundayWithSeven = try CronSchedule(expression: "0 9 * * 7")
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let now = formatter.date(from: "2026-03-13T12:00:00Z")! // Friday
        let nextZero = sundayWithZero.nextDate(after: now, calendar: utcCalendar)
        let nextSeven = sundayWithSeven.nextDate(after: now, calendar: utcCalendar)

        #expect(nextZero == formatter.date(from: "2026-03-15T09:00:00Z"))
        #expect(nextSeven == formatter.date(from: "2026-03-15T09:00:00Z"))
    }

    @Test("throws on invalid field count")
    func invalidFieldCount() {
        #expect(throws: CronExpressionError.self) {
            _ = try CronSchedule(expression: "*/5 * * *")
        }
    }
}
