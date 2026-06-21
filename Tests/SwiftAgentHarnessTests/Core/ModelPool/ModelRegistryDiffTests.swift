import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ModelRegistryDiff")
struct ModelRegistryDiffTests {
    private static func makeModel(
        id: UUID,
        name: String = "model",
        capabilities: [LLMCapability] = [.completion]
    ) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: capabilities,
            modelProtocol: .openAIAPI
        )
    }

    @Test("empty/empty produces no changes")
    func emptyEmpty() {
        let changes = ModelRegistryDiff.compute(previous: [:], next: [:])
        #expect(changes.isEmpty)
    }

    @Test("identical snapshots produce no changes")
    func identicalSnapshots() {
        let id = UUID()
        let model = Self.makeModel(id: id)
        let changes = ModelRegistryDiff.compute(previous: [id: model], next: [id: model])
        #expect(changes.isEmpty)
    }

    @Test("add-only emits one .added per new model in UUID order")
    func addOnly() {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let next: [UUID: Model] = [
            id2: Self.makeModel(id: id2, name: "two"),
            id1: Self.makeModel(id: id1, name: "one")
        ]
        let changes = ModelRegistryDiff.compute(previous: [:], next: next)
        #expect(changes.count == 2)
        #expect(changes[0].kind == .added)
        #expect(changes[0].modelID == id1)
        #expect(changes[0].previous == nil)
        #expect(changes[0].current?.modelName == "one")
        #expect(changes[1].kind == .added)
        #expect(changes[1].modelID == id2)
        #expect(changes[1].current?.modelName == "two")
    }

    @Test("remove-only emits one .removed per missing model with previous populated")
    func removeOnly() {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let previous: [UUID: Model] = [
            id1: Self.makeModel(id: id1, name: "one"),
            id2: Self.makeModel(id: id2, name: "two")
        ]
        let changes = ModelRegistryDiff.compute(previous: previous, next: [:])
        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.kind == .removed })
        #expect(changes.allSatisfy { $0.current == nil })
        #expect(changes[0].modelID == id1)
        #expect(changes[0].previous?.modelName == "one")
        #expect(changes[1].modelID == id2)
    }

    @Test("updated-only emits .updated when fields differ; identical entries are skipped")
    func updatedOnly() {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let previous: [UUID: Model] = [
            id1: Self.makeModel(id: id1, name: "one"),
            id2: Self.makeModel(id: id2, name: "before")
        ]
        let next: [UUID: Model] = [
            id1: Self.makeModel(id: id1, name: "one"),
            id2: Self.makeModel(id: id2, name: "after")
        ]
        let changes = ModelRegistryDiff.compute(previous: previous, next: next)
        #expect(changes.count == 1)
        #expect(changes[0].kind == .updated)
        #expect(changes[0].modelID == id2)
        #expect(changes[0].previous?.modelName == "before")
        #expect(changes[0].current?.modelName == "after")
    }

    @Test("mixed add/remove/update returns deterministic order: removed, then updated, then added")
    func mixedOrdering() {
        let removedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let updatedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let addedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let previous: [UUID: Model] = [
            removedID: Self.makeModel(id: removedID, name: "remove"),
            updatedID: Self.makeModel(id: updatedID, name: "before")
        ]
        let next: [UUID: Model] = [
            updatedID: Self.makeModel(id: updatedID, name: "after"),
            addedID: Self.makeModel(id: addedID, name: "added")
        ]
        let changes = ModelRegistryDiff.compute(previous: previous, next: next)
        #expect(changes.map(\.kind) == [.removed, .updated, .added])
        #expect(changes[0].modelID == removedID)
        #expect(changes[1].modelID == updatedID)
        #expect(changes[2].modelID == addedID)
    }
}
