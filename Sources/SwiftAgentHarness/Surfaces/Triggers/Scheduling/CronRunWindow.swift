import Foundation

enum CronRunWindow {
    static func contains(record: SessionHarnessTaskRunRecord, task: ScheduledTask, now: Date) -> Bool {
        switch task.schedule.kind {
        case .at:
            return true
        case .every:
            guard let ms = task.schedule.intervalMs else { return false }
            return now.timeIntervalSince(record.createdAt) < TimeInterval(ms) / 1000
        case .cron:
            guard let expr = task.schedule.expr, let cron = try? CronSchedule(expression: expr) else { return false }
            guard let nextBoundary = cron.nextDate(after: record.createdAt) else { return true }
            return nextBoundary > now
        }
    }
}
