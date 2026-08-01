import Foundation

enum ScheduledTaskValidationError: Error, Equatable {
    case invalidSchedule(String)
    case scanFailed([String])
    case permanentNotAllowed
    case emptyPayload
    /// A timezone identifier `TimeZone(identifier:)` does not recognise. Refused rather than
    /// defaulted: a task that silently runs in the wrong zone is worse than one that fails to
    /// register, because the failure is visible and the wrong hour is not.
    case unknownTimezone(String)
}

enum ScheduledTaskCreateScanner {
    /// Floor for `every` intervals.
    ///
    /// `intervalMs > 0` alone admits a 1 ms recurring task — an unbounded busy loop with a token
    /// cost attached, i.e. the exact runaway the activation-policy budget stage exists to bound,
    /// registered in a form no per-window budget can absorb gracefully.
    static let minimumIntervalMs: Int64 = 1_000

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
            guard ms >= minimumIntervalMs else {
                return .failure(.invalidSchedule("every requires intervalMs >= \(minimumIntervalMs)"))
            }
        case .cron:
            guard let expr = task.schedule.expr, !expr.isEmpty else {
                return .failure(.invalidSchedule("cron requires expression"))
            }
            if (try? CronSchedule(expression: expr)) == nil {
                return .failure(.invalidSchedule("invalid cron expression"))
            }
        }
        // An empty prompt used to be coerced in at the tool boundary and then fired forever as a
        // no-op turn. Refuse it at the registration boundary instead.
        if task.payloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptyPayload)
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
