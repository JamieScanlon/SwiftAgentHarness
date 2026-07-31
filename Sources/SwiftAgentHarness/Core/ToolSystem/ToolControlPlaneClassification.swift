import Foundation

/// Privilege class for a tool, independent of its allow/deny rules.
///
/// Chat and agent modes grant `allow: ["*"]`, so a newly registered tool is visible by default and
/// the only control is an explicit deny. Without a class, every confined profile has to enumerate
/// privileged tool names by hand — which is how `trigger-delegate` ended up carrying four
/// hard-coded `schedule_*` strings that a fifth registration tool would silently escape.
///
/// `controlPlane` is the one that matters here: trigger registration sits in the same policy bucket
/// as gateway administration and node control, not alongside `read_file`. See
/// `harness-template/surfaces/triggers/self-modification.md` §"Registration is a control-plane
/// capability".
public enum ToolControlPlaneClass: String, Codable, Sendable, Equatable, CaseIterable {
    /// Mutates harness configuration or registers deferred work. Owner + main-agent only.
    case controlPlane = "control-plane"
    /// Can cause code execution on the host.
    case execCapable = "exec-capable"
    /// Requires a live human to answer.
    case interactive
}

/// The single home for privileged tool names and their classes.
///
/// Confined mode profiles derive their deny lists from here rather than restating names, so adding a
/// control-plane tool withholds it everywhere at once.
enum ToolControlPlaneClassification {
    /// Canonical names of the trigger-registration tools.
    ///
    /// Phase 3 collapses these into one action-enum tool per kind; keeping the names in one place
    /// means that rename touches this file plus the provider, not five scattered string literals.
    enum TriggerTools {
        static let scheduleCreate = "schedule_create"
        static let scheduleList = "schedule_list"
        static let scheduleDelete = "schedule_delete"
        static let scheduleFireNow = "schedule_fire_now"
        static let scheduleUpdate = "schedule_update"
        static let schedulePause = "schedule_pause"
        static let scheduleResume = "schedule_resume"
        /// One action-enum tool per kind: 4 kinds x 7 ops would otherwise be 28 tool names.
        static let webhook = "webhook"

        /// Every schedule tool, including the read-only listing.
        static let all: [String] = [
            scheduleCreate,
            scheduleList,
            scheduleDelete,
            scheduleFireNow,
            scheduleUpdate,
            schedulePause,
            scheduleResume,
            webhook,
        ]

        /// The subset whose tool result is a fixed status string rather than task content.
        ///
        /// `scheduleList` is deliberately excluded: it echoes every accessible task's `payloadText`
        /// and `title`, which can originate from a file drop or a channel-hosted conversation, so it
        /// stays inside the external-content envelope.
        static let statusOnlyResults: [String] = [
            scheduleCreate,
            scheduleDelete,
            scheduleFireNow,
            scheduleUpdate,
            schedulePause,
            scheduleResume,
        ]

        /// Tools whose *arguments* can introduce or rewrite a deferred prompt, and therefore need
        /// the create-approval screen.
        static let approvalScreened: [String] = [scheduleCreate, scheduleUpdate]
    }

    private static let table: [String: ToolControlPlaneClass] = {
        var table: [String: ToolControlPlaneClass] = [:]
        for name in TriggerTools.all {
            table[ToolNamePolicyNormalization.canonical(name)] = .controlPlane
        }
        return table
    }()

    static func controlPlaneClass(for toolName: String) -> ToolControlPlaneClass? {
        table[ToolNamePolicyNormalization.canonical(toolName)]
    }

    static func isControlPlane(_ toolName: String) -> Bool {
        controlPlaneClass(for: toolName) == .controlPlane
    }

    /// Deny tokens that every confined profile carries.
    ///
    /// Read-only listing is included: a sub-agent that cannot register a trigger also has no reason
    /// to enumerate the owner's standing automations.
    static var confinedProfileDenyTokens: [String] {
        table.keys.sorted()
    }
}
