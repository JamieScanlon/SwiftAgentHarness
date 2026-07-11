import Testing
import Foundation
import Logging
import SwiftAgentKitSkills
@testable import SwiftAgentHarness

// MARK: - SystemPrompt — Initialization & Properties

@Suite("SystemPrompt — Initialization & Properties")
struct SystemPromptInitTests {

    @Test("Test init with skipConfigLoad creates valid instance")
    func testInitCreatesValidInstance() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.isEmpty == false)
    }

    @Test("includeCurrentDateTime can be overridden via test initializer")
    func includeCurrentDateTimeFromTestInit() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        #expect(prompt.includeCurrentDateTime == false)
    }

    @Test("includeAgentSkills can be overridden via test initializer")
    func includeAgentSkillsFromTestInit() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        #expect(prompt.includeAgentSkills == false)
    }

    @Test("skillLoader is nil when passed nil")
    func skillLoaderNilWhenPassedNil() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        #expect(prompt.skillLoader == nil)
    }

    @Test("Test init with skipConfigLoad creates instance without loading config")
    func testInitSkipsConfig() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        #expect(prompt.skillLoader == nil)
    }

    @Test("Init throws when includeAgentSkills true and skillLoader nil")
    func initThrowsWhenAgentSkillsTrueAndNoLoader() async {
        do {
            _ = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: true, skillLoader: nil, skipConfigLoad: true)
            Issue.record("Expected PromptsConfigError.skillLoaderNotFound")
        } catch SystemPrompt.PromptsConfigError.skillLoaderNotFound {
            // expected
        } catch {
            Issue.record("Expected skillLoaderNotFound, got \(error)")
        }
    }
}

// MARK: - SystemPrompt — Config Loading (Public Init)

@Suite("SystemPrompt — Config Loading")
struct SystemPromptConfigLoadingTests {

    /// Creates a SkillLoader with a temp directory so init can load config when includeAgentSkills is true.
    private static func makeSkillLoaderForConfigLoad() -> SkillLoader {
        SkillLoader(skillsDirectoryURL: FileManager.default.temporaryDirectory, logger: nil)
    }

    @Test("Public init with skillLoader loads options from PromptConfig")
    func loadsOptionsFromConfig() async throws {
        let loader = Self.makeSkillLoaderForConfigLoad()
        let prompt = try await SystemPrompt(skillLoader: loader)
        #expect(prompt.includeCurrentDateTime == true || prompt.includeCurrentDateTime == false)
        #expect(prompt.includeAgentSkills == true || prompt.includeAgentSkills == false)
    }

    @Test("loadSkillsFolderPathFromConfig returns path from PromptConfig")
    func loadsSkillsFolderPathFromConfig() async throws {
        let path = try SystemPrompt.loadSkillsFolderPathFromConfig()
        #expect(path != nil)
        #expect(path?.isEmpty == false)
    }

    @Test("loadSkillsFolderPathFromConfig returns valid path string")
    func skillsFolderPathValidFormat() async throws {
        let path = try SystemPrompt.loadSkillsFolderPathFromConfig() ?? ""
        #expect(path.hasPrefix("/") || path.contains("skills"))
    }
}

// MARK: - SystemPrompt — generateSystemPrompt

@Suite("SystemPrompt — generateSystemPrompt")
struct SystemPromptGenerateTests {

    @Test("generateSystemPrompt returns non-empty string")
    func returnsNonEmpty() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.isEmpty == false)
    }

    @Test("generateSystemPrompt with nil user prompt returns valid output")
    func withNilUserPrompt() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(withUserSystemPrompt: nil)
        #expect(result.isEmpty == false)
    }

    @Test("generateSystemPrompt with empty user prompt returns valid output")
    func withEmptyUserPrompt() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(withUserSystemPrompt: "")
        #expect(result.isEmpty == false)
    }

    @Test("generateSystemPrompt with custom user prompt returns valid output")
    func withCustomUserPrompt() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(withUserSystemPrompt: "You are a helpful assistant.")
        #expect(result.isEmpty == false)
    }

    @Test("Output contains tools environment text")
    func containsToolsEnvironment() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("In this environment you have access to a set of tools you can use to help you gather information and perform tasks."))
    }

    @Test("init throws skillLoaderNotFound when includeAgentSkills true and skillLoader nil")
    func throwsWhenAgentSkillsTrueAndNoSkillLoader() async throws {
        do {
            _ = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: true, skillLoader: nil, skipConfigLoad: true)
            Issue.record("Expected PromptsConfigError.skillLoaderNotFound")
        } catch SystemPrompt.PromptsConfigError.skillLoaderNotFound {
            // expected — with the new SkillLoader API we require a loader when includeAgentSkills is true, so init throws
        } catch {
            Issue.record("Expected skillLoaderNotFound, got \(error)")
        }
    }
}

// MARK: - SystemPrompt — Conversation Metadata

@Suite("SystemPrompt — Conversation metadata")
struct SystemPromptConversationMetadataTests {

    @Test("Conversation metadata is interpolated into the prompt")
    func interpolatesConversationMetadata() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let metadata = [
            "conversationID": "6D7024CF-B11A-4DD9-AE0D-FC70D23650A0",
            "conversationStartDate": "2026-03-16T16:30:00Z",
        ]
        let result = try await prompt.generateSystemPrompt(withUserSystemPrompt: "Be concise.", additionalMetadata: metadata)
        #expect(result.contains("This conversation id is: 6D7024CF-B11A-4DD9-AE0D-FC70D23650A0"))
        #expect(result.contains("This conversation was started on: 2026-03-16T16:30:00Z"))
        #expect(result.contains("{{conversationID}}") == false)
        #expect(result.contains("{{conversationStartDate}}") == false)
    }

    @Test("Conversation metadata defaults to unknown when absent")
    func defaultsConversationMetadataWhenMissing() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(withUserSystemPrompt: nil, additionalMetadata: [:])
        #expect(result.contains("This conversation id is: unknown"))
        #expect(result.contains("This conversation was started on: unknown"))
    }

    @Test("Partial metadata uses provided values and defaults missing keys")
    func partialMetadataFallsBackPerKey() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: ["conversationID": "ABC-123"]
        )
        #expect(result.contains("This conversation id is: ABC-123"))
        #expect(result.contains("This conversation was started on: unknown"))
    }

    @Test("assembleReferenceDateISO freezes datetime token at assemble time")
    func frozenAssembleReferenceDate() async throws {
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let iso = SystemPrompt.assembleReferenceDateISOString(from: frozen)
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: true,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let result = try await prompt.generateSystemPrompt(
            additionalMetadata: [SystemPromptAssemblyMetadataKeys.assembleReferenceDateISO: iso]
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy"
        #expect(result.contains("Today is \(formatter.string(from: frozen))."))
    }
}

@Suite("SystemPrompt — Mode context switches")
struct SystemPromptModeContextSwitchTests {
    @Test("Mode directive metadata renders dedicated section")
    func modeDirectiveSectionAppears() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: ["modeDirective": "Focus on architecture review."]
        )
        #expect(result.contains("# Mode Directive"))
        #expect(result.contains("Focus on architecture review."))
    }

    @Test("Suppressed tools section is removed from rendered prompt")
    func suppressToolsSection() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: ["modeSuppressSections": "tools"]
        )
        #expect(result.contains("# Tools") == false)
    }

    @Test("Section override replaces tool section body")
    func sectionOverrideReplacesToolsSection() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: ["modeSectionOverride.tools": "Use only local static analysis tools."]
        )
        #expect(result.contains("# Tools"))
        #expect(result.contains("Use only local static analysis tools."))
        #expect(result.contains("In this environment you have access to a set of tools you can use to help you gather information and perform tasks.") == false)
    }

    @Test("Memory injection mode off suppresses memory section")
    func memorySectionSuppressedWhenOff() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: ["modeMemoryInjection": "off"]
        )
        #expect(result.contains("# Memory") == false)
    }

    @Test("Tier 1 memory content renders inside Memory section with provenance")
    func tier1MemoryContentInMemorySection() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: [
                "modeMemoryInjection": "on",
                SystemPromptAssemblyMetadataKeys.tier1MemoryContent: "frozen index body",
            ]
        )
        #expect(result.contains("# Memory"))
        #expect(result.contains("frozen index body"))
        #expect(result.contains("<!-- provenance: engine:memory -->"))
        #expect(result.contains("<memory-context>"))
        #expect(result.contains(MemoryContextFencer.systemNote))
    }

    @Test("skills-only with includeSkills false suppresses memory section")
    func skillsOnlyWithoutIncludeSkillsSuppressesMemory() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: nil,
            additionalMetadata: [
                "modeMemoryInjection": "skills-only",
                "modeIncludeSkills": "false",
                SystemPromptAssemblyMetadataKeys.tier1MemoryContent: "should not appear",
            ]
        )
        #expect(result.contains("# Memory") == false)
        #expect(result.contains("should not appear") == false)
    }

    @Test("datetime renders below cache boundary when enabled")
    func datetimeBelowCacheBoundary() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: "dynamic requirement",
            additionalMetadata: [
                SystemPromptAssemblyMetadataKeys.tier1MemoryContent: "stable memory",
            ]
        )
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        let boundaryRange = try #require(result.range(of: marker))
        let todayRange = try #require(result.range(of: "Today is "))
        #expect(todayRange.lowerBound > boundaryRange.lowerBound)
    }

    @Test("cache boundary separates stable prefix from volatile sections")
    func cacheBoundaryBetweenStableAndVolatile() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt(
            withUserSystemPrompt: "dynamic requirement",
            additionalMetadata: [
                "modeMemoryInjection": "on",
                SystemPromptAssemblyMetadataKeys.tier1MemoryContent: "stable memory",
                SystemPromptAssemblyMetadataKeys.providerStablePrefix: "provider prefix",
            ]
        )
        let marker = ProviderPromptContribution.cacheBoundaryMarker
        #expect(result.hasPrefix("provider prefix"))
        #expect(result.contains(marker))
        #expect(result.contains("stable memory"))
        #expect(result.contains("dynamic requirement"))
        let memoryRange = try #require(result.range(of: "stable memory"))
        let additionalRange = try #require(result.range(of: "dynamic requirement"))
        #expect(memoryRange.lowerBound < additionalRange.lowerBound)
    }
}

// MARK: - SystemPrompt — DateTime in Generated Prompt

@Suite("SystemPrompt — DateTime in Generated Prompt")
struct SystemPromptDateTimeTests {

    @Test("Output contains Today is when includeCurrentDateTime is true")
    func containsTodayWhenEnabled() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("Today is "))
    }

    @Test("Date format matches EEEE MMM d yyyy pattern")
    func dateFormat() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains(/Today is \w+, \w+ \d{1,2}, \d{4}\./))
    }

    @Test("Output omits Today is when includeCurrentDateTime is false")
    func omitsTodayWhenDisabled() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("Today is ") == false)
    }
}

// MARK: - SystemPrompt — Agent Skills Section in Template

@Suite("SystemPrompt — Agent Skills in Template")
struct SystemPromptAgentSkillsTests {

    @Test("Output omits Agent Skills section when includeAgentSkills is false")
    func omitsAgentSkillsSectionWhenDisabled() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("You have access to Agent Skills") == false)
        #expect(result.contains("{{agentSkillsMetadata}}") == false)
        #expect(result.contains("Activated Agent Skills:") == false)
    }

    @Test("Output contains base template when skills disabled")
    func baseTemplateWhenSkillsDisabled() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("In this environment you have access to a set of tools"))
    }

    @Test("Output with skills disabled omits agent skills placeholders")
    func skillsDisabledOmitsPlaceholders() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("{{agentSkillsMetadata}}") == false)
        #expect(result.contains("{{activatedAgentSkills}}") == false)
    }

    @Test("Output contains skillsFolderPath dynamic prompt variable when includeAgentSkills true")
    func containsSkillsFolderPathVariable() async throws {
        let skillsURL = URL(fileURLWithPath: "/path/to/skills", isDirectory: true)
        let loader = SkillLoader(skillsDirectoryURL: skillsURL, logger: nil)
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: true, skillLoader: loader, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("The root skills folder is "))
        let expectedPath = await loader.skillsDirectoryURL.absoluteString
        #expect(result.contains(expectedPath))
    }
}

// MARK: - SystemPrompt — Template Combinations

@Suite("SystemPrompt — Template Combinations")
struct SystemPromptTemplateCombinationsTests {

    @Test("Both datetime and tools text when includeCurrentDateTime true")
    func datetimeAndTools() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("Today is "))
        #expect(result.contains("In this environment you have access to a set of tools"))
    }

    @Test("Minimal template when datetime disabled and skills disabled")
    func minimalTemplate() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: false, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result = try await prompt.generateSystemPrompt()
        #expect(result.contains("In this environment you have access to a set of tools"))
        #expect(result.contains("Today is ") == false)
    }
}

// MARK: - SystemPrompt — PromptsConfigError

@Suite("SystemPrompt — PromptsConfigError")
struct SystemPromptErrorTests {

    @Test("PromptsConfigError fileNotFound and invalidJSON are distinct")
    func errorCasesDistinct() {
        let fileNotFound = SystemPrompt.PromptsConfigError.fileNotFound
        let invalidJSON = SystemPrompt.PromptsConfigError.invalidJSON
        switch (fileNotFound, invalidJSON) {
        case (.fileNotFound, .invalidJSON): break
        default: Issue.record("Expected distinct error cases")
        }
    }

    @Test("All three PromptsConfigError cases exist and conform to Error")
    func allErrorCasesConformToError() {
        let errors: [any Error] = [
            SystemPrompt.PromptsConfigError.fileNotFound,
            SystemPrompt.PromptsConfigError.invalidJSON,
            SystemPrompt.PromptsConfigError.skillLoaderNotFound,
        ]
        #expect(errors.count == 3)
    }
}

// MARK: - SystemPrompt — Concurrency

@Suite("SystemPrompt — Concurrency")
struct SystemPromptConcurrencyTests {

    @Test("Concurrent generateSystemPrompt calls do not corrupt output")
    func concurrentGeneration() async throws {
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: true,
            includeAgentSkills: false,
            skillLoader: nil,
            skipConfigLoad: true
        )
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<32 {
                group.addTask {
                    let text = try await prompt.generateSystemPrompt(
                        additionalMetadata: ["conversationID": "id-\(i)"]
                    )
                    return (i, text)
                }
            }
            var collected: [(Int, String)] = []
            for try await pair in group {
                collected.append(pair)
            }
            return collected
        }
        #expect(results.count == 32)
        for (index, text) in results {
            #expect(text.contains("id-\(index)"))
            #expect(text.contains("In this environment you have access to a set of tools"))
        }
    }

    @Test("Concurrent generateSystemPrompt with skills path completes without cross-talk")
    func concurrentGenerationWithSkills() async throws {
        let skillsURL = URL(fileURLWithPath: "/path/to/skills", isDirectory: true)
        let loader = SkillLoader(skillsDirectoryURL: skillsURL, logger: nil)
        let prompt = try await SystemPrompt(
            includeCurrentDateTime: false,
            includeAgentSkills: true,
            skillLoader: loader,
            skipConfigLoad: true
        )
        let expectedPath = await loader.skillsDirectoryURL.absoluteString
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<16 {
                group.addTask {
                    let text = try await prompt.generateSystemPrompt(
                        additionalMetadata: ["conversationID": "skill-run-\(i)"]
                    )
                    return (i, text)
                }
            }
            var collected: [(Int, String)] = []
            for try await pair in group {
                collected.append(pair)
            }
            return collected
        }
        #expect(results.count == 16)
        for (index, text) in results {
            #expect(text.contains("skill-run-\(index)"))
            #expect(text.contains(expectedPath))
        }
    }
}

// MARK: - SystemPrompt — Idempotency

@Suite("SystemPrompt — Idempotency")
struct SystemPromptIdempotencyTests {

    @Test("Multiple generateSystemPrompt calls return consistent structure")
    func multipleCallsConsistent() async throws {
        let prompt = try await SystemPrompt(includeCurrentDateTime: true, includeAgentSkills: false, skillLoader: nil, skipConfigLoad: true)
        let result1 = try await prompt.generateSystemPrompt()
        let result2 = try await prompt.generateSystemPrompt()
        #expect(result1.contains("Today is "))
        #expect(result2.contains("Today is "))
        #expect(result1.contains("In this environment"))
        #expect(result2.contains("In this environment"))
    }
}
