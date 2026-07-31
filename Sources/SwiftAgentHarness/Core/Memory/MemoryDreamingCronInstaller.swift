import Foundation
import Logging

/// Installer-only permanent cron task for nightly dreaming consolidation.
///
/// Goes through ``TriggerRegistrationService`` like every other registration path — the installer's
/// privilege is that it registers under ``RegistrationAuthority/installer``, not that it has its own
/// writer. Installs are **write-if-missing**: once the user deletes this task, the registration
/// layer tombstones the id and this pass stops recreating it.
enum MemoryDreamingCronInstaller {
    static let taskID = MemoryDreamingBridge.dreamTaskID

    /// Install (or refresh) the permanent dream task.
    ///
    /// When `dreamingEnabled` is false, removes any existing task *without* tombstoning it, so
    /// re-enabling the feature in config reinstalls cleanly. That is deliberately different from a
    /// user deletion, which is permanent.
    @discardableResult
    static func ensureInstalled(
        registration: TriggerRegistrationService,
        config: MemoryConfiguration = MemoryConfiguration.default,
        logger: Logger? = nil
    ) throws -> ScheduledTask? {
        guard config.dreamingEnabled else {
            if try registration.uninstallSchedule(id: taskID) {
                logger?.info("[Dreaming] removed permanent cron task id=\(taskID) (dreamingEnabled=false)")
            } else {
                logger?.info("[Dreaming] cron install skipped — dreamingEnabled=false")
            }
            return nil
        }
        guard let saved = try registration.installSchedule(makeSpec(config: config)) else {
            logger?.info("[Dreaming] cron install skipped — task id=\(taskID) was deleted by the user")
            return nil
        }
        logger?.info("[Dreaming] installed permanent cron task id=\(taskID) expr=\(config.dreamingCron)")
        return saved
    }

    static func makeSpec(config: MemoryConfiguration) -> ScheduleRegistrationSpec {
        ScheduleRegistrationSpec(
            id: taskID,
            schedule: ScheduledTaskSchedule(kind: .cron, expr: config.dreamingCron),
            payloadKind: .systemEvent,
            payloadText: MemoryDreamingBridge.dreamPayloadText,
            delivery: .none,
            recurring: true,
            title: "Memory dreaming consolidation",
            requestedTrust: .system,
            permanent: true,
            durable: true
        )
    }
}
