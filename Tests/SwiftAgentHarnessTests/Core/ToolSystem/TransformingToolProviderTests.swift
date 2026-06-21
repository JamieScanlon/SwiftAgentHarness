import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("TransformingToolProvider")
struct TransformingToolProviderTests {
    private struct StubProvider: ToolProvider {
        var name: String { "stub" }

        func availableTools() async -> [ToolDefinition] {
            [ToolDefinition(name: "stub-tool", description: "desc", parameters: [], type: .function)]
        }

        func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
            ToolResult(success: true, content: "raw:\(toolCall.name)", metadata: .object([:]), toolCallId: toolCall.id)
        }

        func executeToolOutcome(_ toolCall: ToolCall) async throws -> ToolExecutionOutcome {
            if toolCall.name == "pending-tool" {
                return .pending(
                    PendingToolHandle(
                        handleID: "handle-1",
                        toolCallID: toolCall.id ?? "missing-call-id",
                        provider: name
                    )
                )
            }
            return .completed(try await executeTool(toolCall))
        }

        func parallelSafety(for toolCall: ToolCall) async -> ToolParallelSafety {
            toolCall.name == "safe-tool" ? .parallelSafe : .unknown
        }

        func registrationSource(for definition: ToolDefinition) async -> ToolRegistrationSource {
            definition.name == "stub-tool" ? .local : .unknown
        }

        func effectClass(for definition: ToolDefinition) async -> ToolEffectClass {
            definition.name == "stub-tool" ? .readOnly : .unknown
        }

        func executionParallelHint(for definition: ToolDefinition) async -> ToolExecutionParallelHint {
            definition.name == "stub-tool" ? .parallelizable : .unknown
        }

        func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
            definition.name == "stub-tool" ? [.requiresApproval] : []
        }

        func rawSchema(for definition: ToolDefinition) async -> JSON? {
            definition.name == "stub-tool"
                ? .object([
                    "type": .string("object"),
                    "properties": .object(["value": .object(["type": .string("string")])]),
                    "required": .array([.string("value")]),
                ])
                : nil
        }
    }

    @Test("executeTool applies async transform output")
    func executeToolAppliesTransform() async throws {
        let provider = TransformingToolProvider(inner: StubProvider()) { toolCall, result in
            ToolResult(
                success: result.success,
                content: "compact:\(toolCall.name)",
                metadata: .object(["kind": .string("transformed")]),
                toolCallId: result.toolCallId
            )
        }
        let call = ToolCall(name: "web-fetch", arguments: .object([:]), id: "call-1")
        let output = try await provider.executeTool(call)
        #expect(output.content == "compact:web-fetch")
        #expect(output.toolCallId == "call-1")
    }

    @Test("executeToolOutcome transforms completed payloads only")
    func executeToolOutcomeTransformsCompletedPayloadOnly() async throws {
        let provider = TransformingToolProvider(inner: StubProvider()) { toolCall, result in
            ToolResult(
                success: result.success,
                content: "compact:\(toolCall.name)",
                metadata: result.metadata,
                toolCallId: result.toolCallId
            )
        }

        let completedCall = ToolCall(name: "safe-tool", arguments: .object([:]), id: "call-2")
        let completedOutcome = try await provider.executeToolOutcome(completedCall)
        switch completedOutcome {
        case .completed(let result):
            #expect(result.content == "compact:safe-tool")
            #expect(result.toolCallId == "call-2")
        case .pending:
            Issue.record("expected completed outcome")
        }

        let pendingCall = ToolCall(name: "pending-tool", arguments: .object([:]), id: "call-3")
        let pendingOutcome = try await provider.executeToolOutcome(pendingCall)
        switch pendingOutcome {
        case .completed:
            Issue.record("expected pending outcome")
        case .pending(let handle):
            #expect(handle.toolCallID == "call-3")
            #expect(handle.provider == "stub")
        }
    }

    @Test("parallelSafety delegates to inner provider")
    func parallelSafetyDelegatesToInnerProvider() async {
        let provider = TransformingToolProvider(inner: StubProvider()) { _, result in result }
        let safe = await provider.parallelSafety(for: ToolCall(name: "safe-tool", arguments: .object([:])))
        let unknown = await provider.parallelSafety(for: ToolCall(name: "other-tool", arguments: .object([:])))
        #expect(safe == .parallelSafe)
        #expect(unknown == .unknown)
    }

    @Test("descriptor metadata methods delegate to inner provider")
    func descriptorMetadataDelegatesToInnerProvider() async {
        let provider = TransformingToolProvider(inner: StubProvider()) { _, result in result }
        let definition = ToolDefinition(name: "stub-tool", description: "desc", parameters: [], type: .function)

        #expect(await provider.registrationSource(for: definition) == .local)
        #expect(await provider.effectClass(for: definition) == .readOnly)
        #expect(await provider.executionParallelHint(for: definition) == .parallelizable)
        #expect(await provider.policyTags(for: definition) == [.requiresApproval])
        #expect(await provider.rawSchema(for: definition) != nil)
    }

    @Test("middleware pipeline runs in deterministic order for runtime stage")
    func middlewarePipelineDeterministicOrdering() async throws {
        let provider = TransformingToolProvider(
            inner: StubProvider(),
            pipeline: ToolResultMiddlewarePipeline(
                registrations: [
                    ToolResultMiddlewareRegistration(
                        id: "z-second",
                        stage: .runtimeDelivery,
                        order: 10
                    ) { _, result in
                        ToolResult(success: result.success, content: "\(result.content)|second", metadata: result.metadata, toolCallId: result.toolCallId)
                    },
                    ToolResultMiddlewareRegistration(
                        id: "a-first",
                        stage: .runtimeDelivery,
                        order: 0
                    ) { _, result in
                        ToolResult(success: result.success, content: "\(result.content)|first", metadata: result.metadata, toolCallId: result.toolCallId)
                    },
                    ToolResultMiddlewareRegistration(
                        id: "persist-only",
                        stage: .persistence,
                        order: 0
                    ) { _, result in
                        ToolResult(success: result.success, content: "\(result.content)|persist", metadata: result.metadata, toolCallId: result.toolCallId)
                    },
                ]
            ),
            stage: .runtimeDelivery
        )
        let output = try await provider.executeTool(ToolCall(name: "web-fetch", arguments: .object([:]), id: "call-4"))
        #expect(output.content == "raw:web-fetch|first|second")
    }

    @Test("debug arguments helper serializes tool-call arguments")
    func debugArgumentsStringSerializesArguments() {
        let call = ToolCall(
            name: "web-search",
            arguments: .object(["query": .string("tool logs"), "limit": .integer(3)]),
            id: "call-debug"
        )
        let encoded = TransformingToolProvider.debugArgumentsString(for: call)
        #expect(encoded.contains(#""query":"tool logs""#))
        #expect(encoded.contains(#""limit":3"#))
    }

    @Test("debug result helper serializes tool result envelope")
    func debugStringSerializesToolResultEnvelope() {
        let result = ToolResult(
            success: false,
            content: "tool failed",
            metadata: .object(["provider": .string("stub")]),
            toolCallId: "call-9",
            error: "boom"
        )
        let encoded = TransformingToolProvider.debugString(for: result)
        #expect(encoded.contains("success=false"))
        #expect(encoded.contains("toolCallId=call-9"))
        #expect(encoded.contains("error=boom"))
        #expect(encoded.contains("provider"))
        #expect(encoded.contains("stub"))
    }
}
