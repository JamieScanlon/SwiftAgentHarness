import EasyJSON
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolCallCapabilityClassifier")
struct ToolCallCapabilityClassifierTests {
    @Test("bash ls is read-only and parallel-safe")
    func bashLsReadOnly() {
        let args = JSON.object(["command": .string("ls -la")])
        let capability = ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args)
        #expect(capability.isReadOnly)
        #expect(capability.isConcurrencySafe)
        #expect(ToolCallCapabilityClassifier.parallelSafety(for: "bash", arguments: args) == .parallelSafe)
    }

    @Test("bash rm is mutating")
    func bashRmMutating() {
        let args = JSON.object(["command": .string("rm -rf /tmp/x")])
        let capability = ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args)
        #expect(!capability.isReadOnly)
        #expect(!capability.isConcurrencySafe)
        #expect(ToolCallCapabilityClassifier.parallelSafety(for: "bash", arguments: args) == .mutating)
    }

    @Test("bash mixed chain with mutating segment fails closed")
    func bashMixedChainMutating() {
        let args = JSON.object(["command": .string("echo ok && rm x")])
        let capability = ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args)
        #expect(!capability.isReadOnly)
    }

    @Test("bash read-only chain stays parallel-safe")
    func bashReadOnlyChain() {
        let args = JSON.object(["command": .string("ls; pwd; cat README.md")])
        let capability = ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args)
        #expect(capability.isReadOnly)
        #expect(capability.isConcurrencySafe)
    }

    @Test("bash redirect fails closed")
    func bashRedirectMutating() {
        let args = JSON.object(["command": .string("echo hi > out.txt")])
        #expect(!ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args).isReadOnly)
    }

    @Test("bash empty command fails closed")
    func bashEmptyMutating() {
        let args = JSON.object(["command": .string("   ")])
        #expect(!ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args).isReadOnly)
    }

    @Test("bash git status is read-only")
    func bashGitStatusReadOnly() {
        let args = JSON.object(["command": .string("git status")])
        #expect(ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args).isReadOnly)
    }

    @Test("bash git commit is mutating")
    func bashGitCommitMutating() {
        let args = JSON.object(["command": .string("git commit -m test")])
        #expect(!ToolCallCapabilityClassifier.classify(toolName: "bash", arguments: args).isReadOnly)
    }

    @Test("process poll is read-only and parallel-safe")
    func processPollReadOnly() {
        let args = JSON.object(["task_id": .string("t1"), "action": .string("poll")])
        let capability = ToolCallCapabilityClassifier.classify(toolName: "process", arguments: args)
        #expect(capability.isReadOnly)
        #expect(capability.isConcurrencySafe)
    }

    @Test("process default action is poll")
    func processDefaultPoll() {
        let args = JSON.object(["task_id": .string("t1")])
        #expect(ToolCallCapabilityClassifier.classify(toolName: "process", arguments: args).isReadOnly)
    }

    @Test("process kill and send_keys are mutating")
    func processMutatingActions() {
        let killArgs = JSON.object(["task_id": .string("t1"), "action": .string("kill")])
        let keysArgs = JSON.object(["task_id": .string("t1"), "action": .string("send_keys")])
        #expect(!ToolCallCapabilityClassifier.classify(toolName: "process", arguments: killArgs).isReadOnly)
        #expect(!ToolCallCapabilityClassifier.classify(toolName: "process", arguments: keysArgs).isReadOnly)
    }

    @Test("callIsReadOnly uses static metadata for monomorphic tools")
    func callIsReadOnlyMonomorphic() {
        let readEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
        let writeEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "write_file", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let args = JSON.object([:])
        #expect(ToolCallCapabilityClassifier.callIsReadOnly(entry: readEntry, arguments: args))
        #expect(!ToolCallCapabilityClassifier.callIsReadOnly(entry: writeEntry, arguments: args))
    }

    @Test("callIsReadOnly classifies polymorphic bash per input")
    func callIsReadOnlyPolymorphicBash() {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let lsArgs = JSON.object(["command": .string("ls")])
        let rmArgs = JSON.object(["command": .string("rm x")])
        #expect(ToolCallCapabilityClassifier.callIsReadOnly(entry: entry, arguments: lsArgs))
        #expect(!ToolCallCapabilityClassifier.callIsReadOnly(entry: entry, arguments: rmArgs))
    }
}
