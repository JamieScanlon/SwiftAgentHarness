import EasyJSON
import SwiftAgentHarness
import Testing

@Suite("ConversationMetadataActivatedSkills")
struct ConversationMetadataActivatedSkillsTests {
    @Test("mergingActivatedAgentSkillNames sorts and merges into root object")
    func mergeSortsAndPreservesOtherKeys() throws {
        let base: JSON = .object([
            "other": .string("x"),
        ])
        let merged = ConversationMetadataActivatedSkills.mergingActivatedAgentSkillNames(
            Set(["zebra", "alpha"]),
            into: base
        )
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: merged) == ["alpha", "zebra"])
        guard case .object(let dict) = merged else {
            Issue.record("expected object")
            return
        }
        guard case .string("x") = dict["other"] else {
            Issue.record("expected other")
            return
        }
    }

    @Test("activatedAgentSkillNames reads string array")
    func readsNames() {
        let meta: JSON = .object([
            ConversationMetadataActivatedSkills.metadataKey: .array([.string("a"), .string("b")]),
        ])
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: meta) == ["a", "b"])
    }

    @Test("mergingPreservingActivatedSkillNames keeps key when incoming omits it")
    func preservesWhenIncomingOmits() throws {
        let existing: JSON = .object([
            ConversationMetadataActivatedSkills.metadataKey: .array([.string("skill-one")]),
            "keep": .string("v"),
        ])
        let incoming: JSON = .object(["newKey": .string("y")])
        let out = ConversationMetadataActivatedSkills.mergingPreservingActivatedSkillNames(existing: existing, incoming: incoming)
        #expect(ConversationMetadataActivatedSkills.activatedAgentSkillNames(from: out) == ["skill-one"])
        guard case .object(let dict) = out else {
            Issue.record("expected object")
            return
        }
        guard case .string("y") = dict["newKey"] else {
            Issue.record("expected newKey")
            return
        }
        #expect(dict["keep"] == nil)
    }
}
