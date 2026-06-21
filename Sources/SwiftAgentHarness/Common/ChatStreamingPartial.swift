import Foundation

/// Canonical assistant streaming fragment emitted on ``ChatStreamResponse/partialContent``.
///
/// This enum is the shared contract used by server/runtime code and transport adapters to
/// describe incremental assistant output while a run is still in progress.
///
/// - ``text(_:)`` carries assistant-visible natural language output.
/// - ``reasoning(_:blockIndex:)`` carries reasoning-channel deltas when the provider exposes them.
/// - ``toolCall(toolName:toolCallId:argumentsFragment:blockIndex:)`` carries streaming tool-call metadata
///   and partial argument payloads.
/// - ``surfaceIntent(_:)`` carries structured client surface actions (e.g. open a validated file for edit).
///
/// Consumers should switch on the case and handle each channel explicitly instead of assuming
/// all fragments are assistant-visible text.
public enum ChatStreamingPartial: Sendable, Equatable {
    /// Assistant-visible text content to render to the user.
    case text(String)
    /// Non-user-visible reasoning fragment, optionally associated with a provider block index.
    case reasoning(String, blockIndex: Int?)
    /// Streaming tool-call fragment with optional name/id and partial serialized arguments.
    case toolCall(toolName: String?, toolCallId: String?, argumentsFragment: String?, blockIndex: Int?)
    /// Structured client surface action emitted by slash commands and other control-plane paths.
    case surfaceIntent(ClientSurfaceIntent)

    /// UTF-8 payload for REST chunked text streaming compatibility.
    ///
    /// Only ``text(_:)`` fragments can be forwarded on raw chunked-text transport.
    /// Other cases intentionally return `nil` because those channels are represented on structured transports.
    public var chunkedTransferUTF8: String? {
        switch self {
        case .text(let s): return s
        case .reasoning, .toolCall, .surfaceIntent: return nil
        }
    }

}
