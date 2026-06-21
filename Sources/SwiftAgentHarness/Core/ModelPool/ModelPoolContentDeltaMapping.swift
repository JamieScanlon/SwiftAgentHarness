import Foundation

/// Maps provider / runtime streaming fragments to harness-shaped ``ModelContentDeltaWire`` values at the pool–runtime boundary.
public enum ModelPoolContentDeltaMapping {
    /// Plain assistant text token or substring chunk from the model stream (v1 default).
    public static func textFragment(
        fragment: String,
        blockIndex: Int? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) -> ModelContentDeltaWire {
        ModelContentDeltaWire(v: 1, kind: .text, index: blockIndex, text: fragment, runId: runId, callId: callId)
    }

    /// Reasoning stream fragment when the provider distinguishes reasoning channels.
    public static func reasoningFragment(
        fragment: String,
        blockIndex: Int? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) -> ModelContentDeltaWire {
        ModelContentDeltaWire(v: 1, kind: .reasoning, index: blockIndex, text: fragment, runId: runId, callId: callId)
    }

    /// Streaming tool-call fragment (name/id stable; arguments may arrive in chunks).
    public static func toolCallFragment(
        toolName: String?,
        toolCallId: String?,
        argumentsFragment: String?,
        blockIndex: Int? = nil,
        runId: UUID? = nil,
        callId: UUID? = nil
    ) -> ModelContentDeltaWire {
        ModelContentDeltaWire(
            v: 1,
            kind: .toolCall,
            index: blockIndex,
            text: nil,
            toolName: toolName,
            toolCallId: toolCallId,
            toolArgumentsFragment: argumentsFragment,
            runId: runId,
            callId: callId
        )
    }
}
