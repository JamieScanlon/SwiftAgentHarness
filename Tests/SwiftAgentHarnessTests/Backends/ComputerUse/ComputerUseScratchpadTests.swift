import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use: specialist scratchpad")
struct ComputerUseScratchpadTests {
    private func call(_ provider: ComputerUseToolProvider, _ name: String, _ arguments: [String: JSON] = [:]) async throws -> ToolResult {
        try await provider.executeTool(ToolCall(name: name, arguments: .object(arguments), id: "call-1"))
    }

    @Test("Notes replace the scratchpad, take no step, and come back in every task reminder")
    func notesComeBack() async throws {
        let (target, session) = try await ComputerUseSessionFixtures.make()
        let provider = ComputerUseToolProvider(session: session)
        let saved = try await call(provider, ComputerUseToolProvider.scratchpadToolName, ["notes": .string("Order number is 4417")])
        #expect(saved.success)
        #expect(await session.scratchpad == "Order number is 4417")
        #expect(await session.stepCount == 0)
        #expect(await target.actCalls.isEmpty)

        let observed = try await call(provider, ComputerUseToolProvider.observeToolName)
        #expect(observed.content.contains("\(ComputerUseToolProvider.reminderHeading):"))
        #expect(observed.content.contains("Your notes: Order number is 4417"))

        _ = try await call(provider, ComputerUseToolProvider.scratchpadToolName, ["notes": .string("Typed it into the form")])
        let next = try await call(provider, ComputerUseToolProvider.observeToolName)
        #expect(next.content.contains("Your notes: Typed it into the form"))
        #expect(!next.content.contains("4417"))
    }

    @Test("Empty notes clear the scratchpad; notes over the limit are refused and kept as they were")
    func clearAndLimit() async throws {
        let (_, session) = try await ComputerUseSessionFixtures.make()
        let provider = ComputerUseToolProvider(session: session)
        _ = try await call(provider, ComputerUseToolProvider.scratchpadToolName, ["notes": .string("keep")])
        let tooLong = try await call(
            provider,
            ComputerUseToolProvider.scratchpadToolName,
            ["notes": .string(String(repeating: "x", count: ComputerUseSession.scratchpadLimit + 1))]
        )
        #expect(!tooLong.success)
        #expect(tooLong.content.contains("\(ComputerUseSession.scratchpadLimit)"))
        #expect(await session.scratchpad == "keep")

        _ = try await call(provider, ComputerUseToolProvider.scratchpadToolName, ["notes": .string("  ")])
        #expect(await session.scratchpad == nil)
    }

    @Test("The scratchpad is a harness tool offered to every specialist, native toolset included, and allowed by its mode")
    func offeredEverywhere() {
        let name = ComputerUseToolProvider.scratchpadToolName
        #expect(ComputerUseToolProvider.toolNames.contains(name))
        #expect(ComputerUseToolProvider.harnessToolNames.contains(name))
        #expect(!ComputerUseToolProvider.screenToolNames.contains(name))
        #expect(ComputerUseToolProvider.nativeCompanionToolNames.contains(name))
        #expect(ComputerUseDelegateToolProvider.specialistToolNames.contains(name))
    }
}
