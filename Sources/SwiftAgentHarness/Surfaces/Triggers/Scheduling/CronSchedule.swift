import Foundation

enum CronExpressionError: Error {
    case invalidFieldCount
    case invalidField(String)
    case invalidNumber(String)
    case outOfRange(String)
    case invalidStep(String)
}

struct CronField {
    let allowed: Set<Int>
    let isWildcard: Bool
}

struct CronSchedule {
    let expression: String
    let minute: CronField
    let hour: CronField
    let dayOfMonth: CronField
    let month: CronField
    let dayOfWeek: CronField

    init(expression: String) throws {
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else {
            throw CronExpressionError.invalidFieldCount
        }

        self.expression = expression
        minute = try CronSchedule.parseField(parts[0], minimum: 0, maximum: 59, normalize: nil)
        hour = try CronSchedule.parseField(parts[1], minimum: 0, maximum: 23, normalize: nil)
        dayOfMonth = try CronSchedule.parseField(parts[2], minimum: 1, maximum: 31, normalize: nil)
        month = try CronSchedule.parseField(parts[3], minimum: 1, maximum: 12, normalize: nil)
        dayOfWeek = try CronSchedule.parseField(parts[4], minimum: 0, maximum: 6) { value in
            value == 7 ? 0 : value
        }
    }

    /// Whether the expression pins the hour, e.g. `30 1 * * *` rather than `30 * * * *`.
    ///
    /// The daylight-saving fall-back rule applies only to pinned-hour jobs: a wildcard-hour job is
    /// asking for every occurrence, and through a repeated hour both 01:xx hours are real elapsed
    /// time. See `TriggerSchedulerService.nextFireDate`.
    var pinsHour: Bool { !hour.isWildcard }

    /// True when the two instants fall in the same local wall-clock minute.
    ///
    /// The fall-back test: during a fall-back the same local minute occurs twice in absolute time,
    /// so equal wall-clock plus distinct instants means the second occurrence of one boundary.
    static func isSameLocalMinute(_ lhs: Date, _ rhs: Date, in timeZone: TimeZone?) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone { calendar.timeZone = timeZone }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        return calendar.dateComponents(fields, from: lhs) == calendar.dateComponents(fields, from: rhs)
    }

    /// Next matching instant, evaluated against wall-clock time in `timeZone`.
    ///
    /// `nil` means "the zone this process happens to run in", which is what every caller got before
    /// tasks could carry a zone. That is preserved rather than switched to UTC because changing it
    /// would silently move every existing recurring task by the deployment's offset; new tasks are
    /// stamped with an explicit zone at registration instead.
    func nextDate(after date: Date, in timeZone: TimeZone?) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone { calendar.timeZone = timeZone }
        return nextDate(after: date, calendar: calendar)
    }

    func nextDate(after date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        let calendar = calendar

        // Floor to the minute in *absolute* time, then step one minute.
        //
        // This replaced `calendar.date(bySettingHour:minute:second:of:)`, which searches forward
        // from the start of the local day and whose default `repeatedTimePolicy` is `.first`. Inside
        // a daylight-saving repeated hour that resolved to the *earlier* of the two 01:xx instants —
        // an hour behind the input — so the walk could re-scan time it had already passed and return
        // a boundary at or before `date`. Every caller assumes the result is strictly later.
        let flooredSeconds = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
        var candidate = Date(timeIntervalSince1970: flooredSeconds + 60)

        // 5 years of minute-resolution search space.
        let maxIterations = 60 * 24 * 366 * 5
        for _ in 0..<maxIterations {
            let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard
                let minuteValue = comps.minute,
                let hourValue = comps.hour,
                let dayValue = comps.day,
                let monthValue = comps.month,
                let weekdayValue = comps.weekday
            else {
                return nil
            }

            let normalizedWeekday = (weekdayValue + 6) % 7
            if matches(
                minute: minuteValue,
                hour: hourValue,
                day: dayValue,
                month: monthValue,
                weekday: normalizedWeekday
            ) {
                return candidate
            }

            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                return nil
            }
            candidate = next
        }
        return nil
    }

    private func matches(minute: Int, hour: Int, day: Int, month: Int, weekday: Int) -> Bool {
        guard
            self.minute.allowed.contains(minute),
            self.hour.allowed.contains(hour),
            self.month.allowed.contains(month)
        else {
            return false
        }

        let dayOfMonthMatch = self.dayOfMonth.allowed.contains(day)
        let dayOfWeekMatch = self.dayOfWeek.allowed.contains(weekday)

        // Cron semantics: if both DOM and DOW are restricted, match when either matches.
        if dayOfMonth.isWildcard && dayOfWeek.isWildcard {
            return true
        } else if dayOfMonth.isWildcard {
            return dayOfWeekMatch
        } else if dayOfWeek.isWildcard {
            return dayOfMonthMatch
        } else {
            return dayOfMonthMatch || dayOfWeekMatch
        }
    }

    private static func parseField(
        _ field: String,
        minimum: Int,
        maximum: Int,
        normalize: ((Int) -> Int)?
    ) throws -> CronField {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        if trimmed == "*" {
            return CronField(allowed: Set(minimum...maximum), isWildcard: true)
        }

        var values = Set<Int>()
        let parts = trimmed.split(separator: ",").map(String.init)
        guard !parts.isEmpty else {
            throw CronExpressionError.invalidField(field)
        }

        for part in parts {
            let partValues = try parsePart(part, minimum: minimum, maximum: maximum, normalize: normalize)
            values.formUnion(partValues)
        }

        guard !values.isEmpty else {
            throw CronExpressionError.invalidField(field)
        }
        return CronField(allowed: values, isWildcard: false)
    }

    private static func parsePart(
        _ part: String,
        minimum: Int,
        maximum: Int,
        normalize: ((Int) -> Int)?
    ) throws -> Set<Int> {
        let components = part.split(separator: "/").map(String.init)
        guard components.count <= 2 else {
            throw CronExpressionError.invalidField(part)
        }

        let base = components[0]
        let step: Int? = {
            guard components.count == 2 else { return nil }
            guard let parsed = Int(components[1]), parsed > 0 else {
                return nil
            }
            return parsed
        }()
        if components.count == 2 && step == nil {
            throw CronExpressionError.invalidStep(part)
        }

        let rangeValues: [Int]
        if base == "*" {
            rangeValues = Array(minimum...maximum)
        } else if base.contains("-") {
            let ends = base.split(separator: "-").map(String.init)
            guard ends.count == 2 else {
                throw CronExpressionError.invalidField(part)
            }
            guard let startRaw = Int(ends[0]), let endRaw = Int(ends[1]) else {
                throw CronExpressionError.invalidNumber(part)
            }
            let start = normalize?(startRaw) ?? startRaw
            let end = normalize?(endRaw) ?? endRaw
            guard start <= end else {
                throw CronExpressionError.invalidField(part)
            }
            guard start >= minimum, end <= maximum else {
                throw CronExpressionError.outOfRange(part)
            }
            rangeValues = Array(start...end)
        } else {
            guard let raw = Int(base) else {
                throw CronExpressionError.invalidNumber(part)
            }
            let value = normalize?(raw) ?? raw
            guard value >= minimum, value <= maximum else {
                throw CronExpressionError.outOfRange(part)
            }
            rangeValues = [value]
        }

        guard let step else {
            return Set(rangeValues)
        }
        let start = rangeValues[0]
        let stepped = rangeValues.filter { (($0 - start) % step) == 0 }
        return Set(stepped)
    }
}
