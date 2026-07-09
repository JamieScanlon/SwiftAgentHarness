import Foundation
import Logging

enum ToolDispatchPlannerNormalization {
    struct EffectiveMode: Sendable, Equatable {
        let mode: ToolPolicyConfiguration.DispatchPlannerMode?
        let wasAllParallelRemapped: Bool
    }

    static func effectivePlannerMode(
        _ configured: ToolPolicyConfiguration.DispatchPlannerMode?
    ) -> EffectiveMode {
        guard let configured else {
            return EffectiveMode(mode: nil, wasAllParallelRemapped: false)
        }
        switch configured {
        case .serial:
            return EffectiveMode(mode: .serial, wasAllParallelRemapped: false)
        case .mixedDeterministic:
            return EffectiveMode(mode: .mixedDeterministic, wasAllParallelRemapped: false)
        case .allParallel:
            return EffectiveMode(mode: .mixedDeterministic, wasAllParallelRemapped: true)
        }
    }

    static func warnIfAllParallelRemapped(
        wasRemapped: Bool,
        fingerprint: String,
        logger: Logger? = nil
    ) {
        guard wasRemapped else { return }
        AllParallelRemapWarningGate.warnOnceIfNeeded(fingerprint: fingerprint, logger: logger)
    }
}

private enum AllParallelRemapWarningGate: Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var seenFingerprints: Set<String> = []

    static func warnOnceIfNeeded(fingerprint: String, logger: Logger?) {
        lock.lock()
        defer { lock.unlock() }
        guard seenFingerprints.insert(fingerprint).inserted else { return }
        let log = logger ?? Logger(label: "SwiftAgentHarness.ToolSystem")
        log.warning(
            "[ToolSystem] dispatch.plannerMode 'allParallel' is not supported; remapped to 'mixedDeterministic'. Use mixedDeterministic or serial per parallel-execution.md."
        )
    }
}
