import Foundation

enum ScheduledTaskValidationError: Error, Equatable {
    case invalidSchedule(String)
    case scanFailed([String])
    case permanentNotAllowed
}

enum ScheduledTaskCreateScanner {
    static func validateCreate(task: ScheduledTask, allowPermanent: Bool = false) -> Result<Void, ScheduledTaskValidationError> {
        if task.permanent, !allowPermanent {
            return .failure(.permanentNotAllowed)
        }
        switch task.schedule.kind {
        case .at:
            guard let at = task.schedule.at, ISO8601DateFormatter().date(from: at) != nil else {
                return .failure(.invalidSchedule("at requires ISO8601 timestamp"))
            }
        case .every:
            guard let ms = task.schedule.intervalMs, ms > 0 else {
                return .failure(.invalidSchedule("every requires positive intervalMs"))
            }
        case .cron:
            guard let expr = task.schedule.expr, !expr.isEmpty else {
                return .failure(.invalidSchedule("cron requires expression"))
            }
            if (try? CronSchedule(expression: expr)) == nil {
                return .failure(.invalidSchedule("invalid cron expression"))
            }
        }
        if task.payloadKind == .agentTurn {
            let scan = ProjectInstructionContentScanner.scan(task.payloadText)
            if !scan.isClean {
                return .failure(.scanFailed(scan.matchedThreatIDs))
            }
        }
        return .success(())
    }
}
