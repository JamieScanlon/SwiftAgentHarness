import Foundation
import Logging
import EasyJSON
import SwiftAgentKit

/// Wraps a ``ToolProvider`` to reshape **runtime** ``ToolResult`` values after `executeTool` and before the orchestrator
/// forwards them to the model (harness **tool-result middleware** seam). This is **not** transcript persistence:
/// ``HarnessRuntimeSession`` still persists tool messages through its SwiftData path separately from this hook.
struct TransformingToolProvider: ToolProvider {
    let inner: any ToolProvider
    let pipeline: ToolResultMiddlewarePipeline
    let stage: ToolResultMiddlewareStage
    let logger: Logger?

    init(
        inner: any ToolProvider,
        pipeline: ToolResultMiddlewarePipeline,
        stage: ToolResultMiddlewareStage = .runtimeDelivery,
        logger: Logger? = nil
    ) {
        self.inner = inner
        self.pipeline = pipeline
        self.stage = stage
        self.logger = logger
    }

    init(
        inner: any ToolProvider,
        transform: @escaping @Sendable (ToolCall, ToolResult) async -> ToolResult
    ) {
        self.init(
            inner: inner,
            pipeline: ToolResultMiddlewarePipeline(
                registrations: [
                    ToolResultMiddlewareRegistration(
                        id: "legacy-transform",
                        stage: .runtimeDelivery,
                        order: 0,
                        transform: transform
                    ),
                ]
            ),
            stage: .runtimeDelivery,
            logger: nil
        )
    }

    var name: String { inner.name }

    func availableTools() async -> [ToolDefinition] {
        await inner.availableTools()
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        let callID = toolCall.id ?? "nil"
        logger?.info("[ToolCalling] Tool call started provider=\(name) tool=\(toolCall.name) callID=\(callID)")
        if DebugPayloadLogging.isEnabled() {
            logger?.debug(
                "[ToolCalling] Tool call parameters provider=\(name) tool=\(toolCall.name) callID=\(callID) arguments=\(Self.debugArgumentsString(for: toolCall))"
            )
        }
        do {
            let raw = try await inner.executeTool(toolCall)
            let transformed = await pipeline.apply(stage: stage, toolCall: toolCall, result: raw)
            logger?.info(
                "[ToolCalling] Tool call response received provider=\(name) tool=\(toolCall.name) callID=\(callID) success=\(transformed.success)"
            )
            if DebugPayloadLogging.isEnabled() {
                logger?.debug(
                    "[ToolCalling] Tool call response payload provider=\(name) tool=\(toolCall.name) callID=\(callID) response=\(Self.debugString(for: transformed))"
                )
            }
            if !transformed.success {
                logger?.error(
                    "[ToolCalling] Tool call returned unsuccessful result provider=\(name) tool=\(toolCall.name) callID=\(callID) error=\(transformed.error ?? "nil")"
                )
            }
            return transformed
        } catch {
            logger?.error(
                "[ToolCalling] Tool call failed provider=\(name) tool=\(toolCall.name) callID=\(callID) error=\(error)"
            )
            throw error
        }
    }

    func executeToolOutcome(_ toolCall: ToolCall) async throws -> ToolExecutionOutcome {
        let callID = toolCall.id ?? "nil"
        logger?.info("[ToolCalling] Tool call started provider=\(name) tool=\(toolCall.name) callID=\(callID)")
        if DebugPayloadLogging.isEnabled() {
            logger?.debug(
                "[ToolCalling] Tool call parameters provider=\(name) tool=\(toolCall.name) callID=\(callID) arguments=\(Self.debugArgumentsString(for: toolCall))"
            )
        }
        do {
            let outcome = try await inner.executeToolOutcome(toolCall)
            switch outcome {
            case .completed(let result):
                let transformed = await pipeline.apply(stage: stage, toolCall: toolCall, result: result)
                logger?.info(
                    "[ToolCalling] Tool call response received provider=\(name) tool=\(toolCall.name) callID=\(callID) success=\(transformed.success)"
                )
                if DebugPayloadLogging.isEnabled() {
                    logger?.debug(
                        "[ToolCalling] Tool call response payload provider=\(name) tool=\(toolCall.name) callID=\(callID) response=\(Self.debugString(for: transformed))"
                    )
                }
                if !transformed.success {
                    logger?.error(
                        "[ToolCalling] Tool call returned unsuccessful result provider=\(name) tool=\(toolCall.name) callID=\(callID) error=\(transformed.error ?? "nil")"
                    )
                }
                return .completed(transformed)
            case .pending(let handle):
                // Pending-first semantics are owned by provider/orchestrator handle flow; transform applies only to completed payloads.
                logger?.info(
                    "[ToolCalling] Tool call pending provider=\(name) tool=\(toolCall.name) callID=\(callID) handleID=\(handle.handleID)"
                )
                return .pending(handle)
            }
        } catch {
            logger?.error(
                "[ToolCalling] Tool call failed provider=\(name) tool=\(toolCall.name) callID=\(callID) error=\(error)"
            )
            throw error
        }
    }

    func cancelPending(handleID: String, toolCallID: String) async -> Bool {
        await inner.cancelPending(handleID: handleID, toolCallID: toolCallID)
    }

    func parallelSafety(for toolCall: ToolCall) async -> ToolParallelSafety {
        await inner.parallelSafety(for: toolCall)
    }

    func registrationSource(for definition: ToolDefinition) async -> ToolRegistrationSource {
        await inner.registrationSource(for: definition)
    }

    func effectClass(for definition: ToolDefinition) async -> ToolEffectClass {
        await inner.effectClass(for: definition)
    }

    func executionParallelHint(for definition: ToolDefinition) async -> ToolExecutionParallelHint {
        await inner.executionParallelHint(for: definition)
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        await inner.policyTags(for: definition)
    }

    func rawSchema(for definition: ToolDefinition) async -> JSON? {
        await inner.rawSchema(for: definition)
    }

    static func debugArgumentsString(for toolCall: ToolCall) -> String {
        guard let data = try? JSONEncoder().encode(toolCall.arguments),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: toolCall.arguments)
        }
        return string
    }

    static func debugString(for result: ToolResult) -> String {
        "success=\(result.success) toolCallId=\(result.toolCallId ?? "nil") error=\(result.error ?? "nil") content=\(result.content) metadata=\(String(describing: result.metadata))"
    }
}
