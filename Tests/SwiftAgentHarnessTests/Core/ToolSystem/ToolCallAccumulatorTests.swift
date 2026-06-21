import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolCallAccumulator (cross-provider tool-call dedupe)")
struct ToolCallAccumulatorTests {

    // MARK: - ingestFinalList (Ollama done-chunk path)

    @Test("ingestFinalList collapses repeated identical lists into one entry per id")
    func finalListIdempotentById() {
        var acc = ToolCallAccumulator()
        let list = [
            ToolCall(name: "lookup", arguments: .object(["q": .string("x")]), id: "tc-1")
        ]
        acc.ingestFinalList(list)
        acc.ingestFinalList(list)
        acc.ingestFinalList(list)
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].id == "tc-1")
        #expect(result[0].name == "lookup")
    }

    @Test("ingestFinalList collapses repeats by (name, arguments) when id is missing")
    func finalListIdempotentByNameAndArgs() {
        var acc = ToolCallAccumulator()
        let list = [
            ToolCall(name: "lookup", arguments: .object(["q": .string("x")]), id: nil)
        ]
        acc.ingestFinalList(list)
        acc.ingestFinalList(list)
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].name == "lookup")
    }

    @Test("ingestFinalList ignores empty lists (does not overwrite previously ingested data)")
    func finalListIgnoresEmpty() {
        var acc = ToolCallAccumulator()
        let list = [ToolCall(name: "a", arguments: .object([:]), id: "id-a")]
        acc.ingestFinalList(list)
        acc.ingestFinalList([])
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].id == "id-a")
    }

    // MARK: - ingestIndexed (LM Studio + OpenAI delta path)

    @Test("ingestIndexed merges name + argument fragments across deltas in numerical index order")
    func indexedDeltasMergeAndOrder() {
        var acc = ToolCallAccumulator()
        // First delta: index 1 carries id and name only.
        acc.ingestIndexed(index: 1, idDelta: "id-b", nameDelta: "second", argumentsDelta: nil)
        // Second delta: index 0 carries id and name only.
        acc.ingestIndexed(index: 0, idDelta: "id-a", nameDelta: "first", argumentsDelta: nil)
        // Argument fragments arrive across multiple chunks per index.
        acc.ingestIndexed(index: 0, idDelta: nil, nameDelta: nil, argumentsDelta: "{\"a\":")
        acc.ingestIndexed(index: 0, idDelta: nil, nameDelta: nil, argumentsDelta: "1}")
        acc.ingestIndexed(index: 1, idDelta: nil, nameDelta: nil, argumentsDelta: "{\"b\":2}")

        let result = acc.finalize()
        #expect(result.count == 2)
        #expect(result[0].name == "first")
        #expect(result[0].id == "id-a")
        if case .object(let dict) = result[0].arguments {
            #expect(dict["a"] != nil)
        } else {
            Issue.record("expected first call arguments to parse as object")
        }
        #expect(result[1].name == "second")
        #expect(result[1].id == "id-b")
    }

    @Test("ingestIndexed without name on any delta drops the entry on finalize")
    func indexedWithoutNameDrops() {
        var acc = ToolCallAccumulator()
        acc.ingestIndexed(index: 0, idDelta: "abc", nameDelta: nil, argumentsDelta: "{}")
        let result = acc.finalize()
        #expect(result.isEmpty)
    }

    @Test("ingestIndexed without arguments yields default {} arguments")
    func indexedWithoutArgsDefaultsToEmpty() {
        var acc = ToolCallAccumulator()
        acc.ingestIndexed(index: 0, idDelta: "id", nameDelta: "noop", argumentsDelta: nil)
        let result = acc.finalize()
        #expect(result.count == 1)
        if case .object(let dict) = result[0].arguments {
            #expect(dict.isEmpty)
        } else {
            Issue.record("expected empty .object arguments")
        }
    }

    // MARK: - ingestNameAndArgs (OpenAI fragment fallback)

    @Test("ingestNameAndArgs accumulates argument fragments by id")
    func fragmentByIdAccumulates() {
        var acc = ToolCallAccumulator()
        acc.ingestNameAndArgs(id: "tc-1", name: "search", argumentsFragment: "{\"q\":")
        acc.ingestNameAndArgs(id: "tc-1", name: "search", argumentsFragment: "\"hello\"")
        acc.ingestNameAndArgs(id: "tc-1", name: "search", argumentsFragment: "}")
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].name == "search")
        #expect(result[0].id == "tc-1")
        if case .object(let dict) = result[0].arguments,
           case .string(let q)? = dict["q"] {
            #expect(q == "hello")
        } else {
            Issue.record("expected merged arguments to parse as {\"q\":\"hello\"}")
        }
    }

    @Test("ingestNameAndArgs falls back to merging by name when id is missing")
    func fragmentByNameWhenIdMissing() {
        var acc = ToolCallAccumulator()
        acc.ingestNameAndArgs(id: nil, name: "search", argumentsFragment: "{\"q\":")
        acc.ingestNameAndArgs(id: nil, name: "search", argumentsFragment: "\"x\"}")
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].name == "search")
    }

    @Test("ingestNameAndArgs drops fragments that never carry a name")
    func fragmentDroppedWithoutName() {
        var acc = ToolCallAccumulator()
        acc.ingestNameAndArgs(id: "tc-1", name: nil, argumentsFragment: "{\"q\":1}")
        #expect(acc.finalize().isEmpty)
    }

    @Test("finalList overrides incomplete name+args fragment for the same id")
    func finalListOverridesIncompleteFragment() {
        var acc = ToolCallAccumulator()
        acc.ingestNameAndArgs(id: "387522868", name: "get_plan", argumentsFragment: "")
        acc.ingestFinalList([
            ToolCall(
                name: "get_plan",
                arguments: .object(["conversation_id": .string("6EB8FBC6-66DE-4058-B563-C2EA353A46EC")]),
                id: "387522868"
            )
        ])
        let result = acc.finalize()
        #expect(result.count == 1)
        if case .object(let dict) = result[0].arguments,
           case .string(let cid)? = dict["conversation_id"] {
            #expect(cid == "6EB8FBC6-66DE-4058-B563-C2EA353A46EC")
        } else {
            Issue.record("expected conversation_id in finalized arguments")
        }
    }

    @Test("fragment merges args-only delta via lastOpenFragmentKey when id and name are absent")
    func fragmentMergesArgsOnlyDeltaByLastOpenCall() {
        var acc = ToolCallAccumulator()
        acc.ingestNameAndArgs(id: "387522868", name: "get_plan", argumentsFragment: "")
        acc.ingestNameAndArgs(
            id: nil,
            name: nil,
            argumentsFragment: "{\"conversation_id\":\"6EB8FBC6-66DE-4058-B563-C2EA353A46EC\"}"
        )
        let result = acc.finalize()
        #expect(result.count == 1)
        if case .object(let dict) = result[0].arguments,
           case .string(let cid)? = dict["conversation_id"] {
            #expect(cid == "6EB8FBC6-66DE-4058-B563-C2EA353A46EC")
        } else {
            Issue.record("expected conversation_id in merged arguments")
        }
    }

    @Test("fragment merges args-only delta by id when name is absent")
    func fragmentMergesArgsOnlyDeltaById() {
        var acc = ToolCallAccumulator()
        acc.ingestNameAndArgs(id: "387522868", name: "get_plan", argumentsFragment: "")
        acc.ingestNameAndArgs(
            id: "387522868",
            name: nil,
            argumentsFragment: "{\"conversation_id\":\"6EB8FBC6-66DE-4058-B563-C2EA353A46EC\"}"
        )
        let result = acc.finalize()
        #expect(result.count == 1)
        if case .object(let dict) = result[0].arguments,
           case .string(let cid)? = dict["conversation_id"] {
            #expect(cid == "6EB8FBC6-66DE-4058-B563-C2EA353A46EC")
        } else {
            Issue.record("expected conversation_id in merged arguments")
        }
    }

    // MARK: - Mixed paths into the same accumulator

    @Test("mixed paths into the same accumulator do not double-emit overlapping ids")
    func mixedPathsDedupeById() {
        var acc = ToolCallAccumulator()
        // Indexed path first (LM Studio / OpenAI delta).
        acc.ingestIndexed(index: 0, idDelta: "id-shared", nameDelta: "shared", argumentsDelta: "{\"x\":1}")
        // Name+args fragment path with the same id (OpenAI fallback).
        acc.ingestNameAndArgs(id: "id-shared", name: "shared", argumentsFragment: "{\"x\":1}")
        // Final-list path repeats the same id (Ollama done-chunk).
        acc.ingestFinalList([
            ToolCall(name: "shared", arguments: .object(["x": .integer(1)]), id: "id-shared")
        ])
        let result = acc.finalize()
        #expect(result.count == 1)
        #expect(result[0].id == "id-shared")
        #expect(result[0].name == "shared")
    }

    @Test("final list with new ids is appended after indexed entries")
    func finalListAppendsAfterIndexed() {
        var acc = ToolCallAccumulator()
        acc.ingestIndexed(index: 0, idDelta: "id-a", nameDelta: "alpha", argumentsDelta: "{}")
        acc.ingestFinalList([
            ToolCall(name: "alpha", arguments: .object([:]), id: "id-a"),
            ToolCall(name: "beta", arguments: .object([:]), id: "id-b")
        ])
        let result = acc.finalize()
        #expect(result.count == 2)
        #expect(result[0].name == "alpha")
        #expect(result[1].name == "beta")
    }

    @Test("empty accumulator finalizes to []")
    func emptyAccumulator() {
        let acc = ToolCallAccumulator()
        #expect(acc.finalize().isEmpty)
    }
}
