import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("PromptConfigDocument")
struct PromptConfigDocumentTests {
    @Test("Empty object parses with no unknown keys")
    func emptyObjectParses() throws {
        let document = try PromptConfigDocument.parse(data: Data("{}".utf8))
        #expect(document.unknownTopLevelKeys.isEmpty)
        #expect(document.options == nil)
        #expect(document.agentHarness == nil)
        #expect(document.foundationRoot()?.isEmpty == true)
    }

    @Test("static empty matches parse of empty object")
    func staticEmpty() {
        #expect(PromptConfigDocument.empty.unknownTopLevelKeys.isEmpty)
        #expect(PromptConfigDocument.empty.foundationRoot()?.isEmpty == true)
    }

    @Test("Known sections are exposed and unknown top-level keys are collected")
    func knownAndUnknownKeys() throws {
        let json = """
        {
          "options": { "includeAgentSkills": false },
          "agentHarness": { "strictAgentHarnessPrompts": true },
          "modeProfiles": [],
          "extraExperimental": { "x": 1 },
          "anotherUnknown": 2
        }
        """
        let document = try PromptConfigDocument.parse(data: Data(json.utf8))
        #expect(document.options != nil)
        #expect(document.agentHarness != nil)
        #expect(document.modeProfiles != nil)
        #expect(document.unknownTopLevelKeys == ["anotherUnknown", "extraExperimental"])
        #expect(document.foundationObject(forKey: "options")?["includeAgentSkills"] as? Bool == false)
    }

    @Test("Non-object root throws")
    func nonObjectRootThrows() {
        #expect(throws: PromptConfigDocumentError.invalidRoot) {
            _ = try PromptConfigDocument.parse(data: Data("[1,2]".utf8))
        }
    }

    @Test("Test fixture has expected sections")
    func testFixtureSections() throws {
        guard let url = Bundle.module.url(forResource: "PromptConfig", withExtension: "json") else {
            Issue.record("PromptConfig.json fixture not in test bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let document = try PromptConfigDocument.parse(data: data)
        #expect(document.options != nil)
        #expect(document.settings != nil)
        #expect(document.agentHarness != nil)
        #expect(document.toolPolicy != nil)
        #expect(document.subAgentHostingPolicy != nil)
        #expect(document.modeProfiles != nil)
        #expect(document.memory != nil)
        #expect(document.unknownTopLevelKeys.isEmpty)
    }
}
