import EasyJSON
import Foundation
import SwiftAgentKit

enum ChannelToolError: Error, Equatable {
    case nameRequired
    case unknownChannel(String)
    case notConfigured
    case unavailable

    var code: String {
        switch self {
        case .nameRequired: return "name_required"
        case .unknownChannel(let name): return "unknown_channel:\(name)"
        case .notConfigured: return "not_configured"
        case .unavailable: return "channel_lifecycle_unavailable"
        }
    }
}

/// The agent-facing channel control plane — **read-only, deliberately**.
///
/// `RegistrationPolicy.allowsRegistration(_:kind: .channel)` denies `agent` and `subAgent`, so a
/// mutation action here would be a button that always returns "denied": it would burn turns, teach
/// the model to retry, and imply a capability that does not exist. The schema advertises only what
/// the caller can actually have.
///
/// The reads earn their place. "Why did my Slack messages stop arriving?" is a question the agent is
/// asked directly and could not previously answer — the state lived in `channel-status/*.json` on
/// disk and in nothing the model could see.
///
/// Registered in `ToolControlPlaneClassification.TriggerTools`, so it inherits the control-plane
/// sender deny rung and the confined-profile deny tokens without restating either. Read-only is not
/// an exemption from that: a sub-agent with no authority to change a channel has no reason to
/// enumerate the owner's, and the same reasoning already covers `schedule_list`.
public struct ChannelToolProvider: ToolProvider {
    private let dataService: ScheduledTaskToolDataService

    init(dataService: ScheduledTaskToolDataService) {
        self.dataService = dataService
    }

    public var name: String { "ChannelTools" }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: ToolControlPlaneClassification.TriggerTools.channel,
                description: "Inspect messaging channel listeners (Slack, Telegram, Discord, email). Read-only: enabling, disabling and reloading a channel are owner operations and are not available here — tell the user to use the operator CLI rather than retrying. Useful for answering \"why did my messages stop arriving\".",
                parameters: [
                    .init(name: "action", description: "list | get", type: "string", required: true),
                    .init(name: "channel", description: "Channel id (slack, telegram, discord, email). Required for get.", type: "string", required: false),
                ],
                type: .function
            ),
        ]
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        var toolCall = toolCall
        if TriggerToolArgumentBridge.isSlashDispatch(toolCall.arguments) {
            guard let mapped = TriggerToolArgumentBridge.channelArguments(from: toolCall.arguments) else {
                return err(toolCall, "usage: list | get <channel>")
            }
            toolCall = ToolCall(name: toolCall.name, arguments: mapped, id: toolCall.id)
        }
        do {
            let action = Self.string(toolCall.arguments, "action") ?? "list"
            switch action {
            case "list", "status":
                return ok(toolCall, try await list())
            case "get":
                return ok(toolCall, try await get(toolCall))
            case "enable", "disable":
                // Named explicitly rather than falling into "unknown action": the difference between
                // "that verb does not exist" and "that verb exists and you may not have it" is the
                // difference between a model that retries with synonyms and one that tells the user.
                //
                // Only the two verbs the CLI actually implements are listed. Naming a command that
                // does not exist is worse than refusing without a suggestion — `reload` has no owner
                // client at all, so it stays an unknown action here rather than sending the user to
                // a subcommand that errors out.
                let channel = Self.string(toolCall.arguments, "channel") ?? "<channel>"
                return err(
                    toolCall,
                    "owner_only: changing channel lifecycle is an owner operation and is not available from this tool. The user can run it from the operator CLI: `trigger channel \(action) \(channel) --data-directory <path>`."
                )
            default:
                return err(toolCall, "unknown action \(action)")
            }
        } catch let error as ChannelToolError {
            return err(toolCall, error.code)
        } catch {
            return err(toolCall, String(describing: error))
        }
    }

    // MARK: - Actions

    private func list() async throws -> String {
        let summaries = try await dataService.listChannels()
        guard !summaries.isEmpty else {
            return "no channel listeners configured (nothing enabled in channels.json, or no transport implemented for the ones that are)"
        }
        return summaries.map(Self.render).joined(separator: "\n")
    }

    private func get(_ toolCall: ToolCall) async throws -> String {
        guard let raw = Self.string(toolCall.arguments, "channel") else { throw ChannelToolError.nameRequired }
        guard let channel = ChannelId(rawValue: raw.lowercased()) else {
            throw ChannelToolError.unknownChannel(raw)
        }
        guard let summary = try await dataService.channelStatus(channel) else {
            throw ChannelToolError.notConfigured
        }
        return Self.render(summary)
    }

    /// One line per channel, all fields drawn from enums and booleans.
    ///
    /// Nothing here is attacker-reachable text — that is what lets `channel` sit in
    /// `statusOnlyResults` alongside `schedule_create` rather than inside the external-content
    /// envelope with `schedule_list`. `fatalCode` is one of a fixed set this codebase writes; the
    /// fatal *message*, which is `String(describing:)` of a transport error and can carry a URL or a
    /// rejected token, never leaves `ChannelStatusSummary`.
    private static func render(_ summary: ChannelStatusSummary) -> String {
        var parts = [
            summary.channel.rawValue,
            "transport=\(summary.transport.rawValue)",
            "config=\(summary.configEnabled ? "enabled" : "disabled")",
            "runtime=\(summary.runtimeDisabled ? "paused" : "active")",
            "running=\(summary.running)",
            "state=\(summary.state.rawValue)",
        ]
        if !summary.serviceBuilt {
            // The answer to "it is in my config, why is nothing happening": either it was off when
            // the process started (listeners are built once, at boot) or its transport is a stub.
            parts.append("listener=none(needs-restart-or-unimplemented-transport)")
        }
        if let fatalCode = summary.fatalCode {
            // Present even when running: the listener has no way to clear a recorded fatal, so
            // `running=true` alongside this reads as "failed, then recovered".
            parts.append("lastFatal=\(fatalCode)")
        }
        if summary.overlayUnreadable {
            parts.append("overlayUnreadable=true")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Argument access

    private static func string(_ arguments: JSON, _ key: String) -> String? {
        guard case .object(let dict) = arguments, let value = dict[key], case .string(let text) = value else { return nil }
        return text.isEmpty ? nil : text
    }

    private func ok(_ toolCall: ToolCall, _ content: String) -> ToolResult {
        ToolResult(success: true, content: content, metadata: .object(["source": .string("channel_tools")]), toolCallId: toolCall.id)
    }

    private func err(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(success: false, content: "", metadata: .object(["source": .string("channel_tools")]), toolCallId: toolCall.id, error: message)
    }
}
