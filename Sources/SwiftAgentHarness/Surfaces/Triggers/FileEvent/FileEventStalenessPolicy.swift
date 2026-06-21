import Foundation

enum FileEventStartupAction: Sendable, Equatable {
    case delete
    case consume(missed: Bool)
    case registerPeriodic
    case deferOneShot(until: Date)
}

enum FileEventStalenessPolicy {
    static func startupAction(
        payload: FileEventPayload,
        fileModificationDate: Date,
        harnessStartTime: Date,
        now: Date = Date()
    ) -> FileEventStartupAction {
        switch payload.type {
        case .immediate:
            if fileModificationDate < harnessStartTime {
                return .delete
            }
            return .consume(missed: false)
        case .oneShot:
            guard let atRaw = payload.at,
                  let atDate = ISO8601DateFormatter().date(from: atRaw) else {
                return .consume(missed: false)
            }
            if atDate > now {
                return .deferOneShot(until: atDate)
            }
            return .consume(missed: atDate < harnessStartTime)
        case .periodic:
            return .registerPeriodic
        }
    }
}
