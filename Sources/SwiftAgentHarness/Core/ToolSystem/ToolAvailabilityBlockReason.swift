import Foundation

/// Labels why a tool name may be excluded from the **model-facing** tool list (harness gateway-style gate).
/// Filtering logic lives in `DefaultToolSystemGateway.effectiveToolsForConversation`; this enum is for diagnostics,
/// tests, and future structured logging — not a second policy implementation.
public enum ToolAvailabilityBlockReason: String, Sendable, CaseIterable, Equatable {
    /// `HarnessRuntimeSession.Configuration.enableTools` is false for this send.
    case toolsDisabledForSend
    /// A2A-registered tool and `enableAgents` is false.
    case agentsDisabledForRemoteAgentTool
    /// `ToolPolicyConfiguration` allowlist rejects this mode/phase (PromptConfig).
    case promptConfigAllowlist
    /// `ToolPolicyConfiguration` denylist rejects this tool for mode/phase.
    case promptConfigDenylist
    /// Tool is marked escalation-required and this invocation is not elevated.
    case escalationRequired
    /// Tool requires explicit approval (or is elevated) and no pre-approval exists for this run.
    case approvalRequired
    /// Tool blocked by execution-environment policy (transport/isolation constraints).
    case executionEnvironmentPolicyDenied
    /// Delegate tool blocked because current conversation depth reached the delegate recursion limit.
    case recursionDepthExceeded
    /// Delegate tool blocked by configured hosting/routing policy isolation.
    case hostingRoutingPolicyDenied
    /// Conversation-level `routing.toolWhitelist` intersection rejects this tool.
    case routingToolWhitelist
}
