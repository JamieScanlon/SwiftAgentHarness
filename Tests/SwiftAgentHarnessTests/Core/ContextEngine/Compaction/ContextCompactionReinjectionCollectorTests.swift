import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextCompactionReinjectionCollector (CR-F)")
struct ContextCompactionReinjectionCollectorTests {
    private func config(_ mutate: (inout ContextCompactionConfiguration) -> Void = { _ in }) -> ContextCompactionConfiguration {
        var c = ContextCompactionConfiguration.default
        mutate(&c)
        return c
    }

    private func fileAccess(path: String, content: String?, id: String) -> [Message] {
        var messages: [Message] = [
            Message(
                id: UUID(),
                role: .assistant,
                content: "calling read_file",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "read_file", arguments: .object(["path": .string(path)]), id: id)]
            ),
        ]
        if let content {
            messages.append(
                Message(
                    id: UUID(),
                    role: .tool,
                    content: content,
                    timestamp: Date(),
                    toolCalls: [],
                    toolCallId: id
                )
            )
        }
        return messages
    }

    // MARK: - File content re-injection

    @Test("Per-file content is truncated to the per-file token budget")
    func perFileCapTruncates() {
        let big = String(repeating: "x", count: 40_000) // ~10k tokens at cpt 4
        let messages = fileAccess(path: "big.txt", content: big, id: "c1")
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: messages, tail: [], skills: [], instructionContext: nil, config: config()
        )
        let fileMsg = out.first { $0.content.contains("recent file content") }
        #expect(fileMsg != nil)
        #expect(fileMsg?.content.contains("truncated for context re-injection") == true)
        // per-file budget 5k tokens * 4 cpt = 20k chars (+ header + marker)
        #expect((fileMsg?.content.count ?? .max) < 21_000)
    }

    @Test("Total file budget drops later files whole")
    func totalFileCapDropsLaterFiles() {
        let cfg = config {
            $0.reinjectionRecentFileCount = 5
            $0.reinjectionPerFileTokenBudget = 5_000
            $0.reinjectionTotalFileTokenBudget = 12_000
        }
        let big = String(repeating: "y", count: 40_000) // capped to 20k chars => ~5k tokens
        var messages: [Message] = []
        // Most-recent-first ordering: last appended is most recent. Provide 3 large files.
        for i in 0..<3 {
            messages.append(contentsOf: fileAccess(path: "f\(i).txt", content: big, id: "c\(i)"))
        }
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: messages, tail: [], skills: [], instructionContext: nil, config: cfg
        )
        let fileMsgs = out.filter { $0.content.contains("recent file content") }
        // 5k + 5k = 10k <= 12k; third would push to 15k => dropped whole.
        #expect(fileMsgs.count == 2)
    }

    @Test("File with no resolvable content falls back to a path-only line")
    func pathFallbackWhenNoContent() {
        let messages = fileAccess(path: "lonely.swift", content: nil, id: "c1")
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: messages, tail: [], skills: [], instructionContext: nil, config: config()
        )
        let fallback = out.first { $0.content.contains("lonely.swift") }
        #expect(fallback != nil)
        #expect(fallback?.content.contains("content is unavailable") == true)
        #expect(out.contains { $0.content.contains("recent file content") } == false)
    }

    @Test("Disabled file content mode reproduces the path-only list")
    func disabledModePathList() {
        let cfg = config { $0.reinjectFileContentEnabled = false }
        let probe = Message(
            id: UUID(),
            role: .assistant,
            content: "read_file with path \"config.py\"",
            timestamp: Date(),
            toolCalls: []
        )
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [probe], tail: [], skills: [], instructionContext: nil, config: cfg
        )
        let list = out.first { $0.content.contains("recent files") }
        #expect(list != nil)
        #expect(list?.content.contains("config.py") == true)
        #expect(out.contains { $0.content.contains("recent file content") } == false)
    }

    // MARK: - Skill re-injection

    @Test("Active skills are re-injected and truncated to the per-skill budget")
    func skillReinjectionTruncates() {
        let big = String(repeating: "s", count: 40_000)
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [], tail: [],
            skills: [ReinjectableSkill(name: "deepdive", content: big)],
            instructionContext: nil,
            config: config()
        )
        let skillMsg = out.first { $0.content.contains("active skill: deepdive") }
        #expect(skillMsg != nil)
        #expect(skillMsg?.content.contains("truncated for context re-injection") == true)
    }

    @Test("Total skill budget drops later skills whole")
    func totalSkillCapDropsLaterSkills() {
        let cfg = config {
            $0.reinjectionPerSkillTokenBudget = 5_000
            $0.reinjectionTotalSkillTokenBudget = 8_000
        }
        let big = String(repeating: "s", count: 40_000) // capped to 20k chars => ~5k tokens
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [], tail: [],
            skills: [
                ReinjectableSkill(name: "alpha", content: big),
                ReinjectableSkill(name: "beta", content: big),
            ],
            instructionContext: nil,
            config: cfg
        )
        let skillMsgs = out.filter { $0.content.contains("active skill:") }
        #expect(skillMsgs.count == 1)
        #expect(skillMsgs.first?.content.contains("alpha") == true)
    }

    @Test("No active skills => no skill attachment")
    func noSkillsNoAttachment() {
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [], tail: [], skills: [], instructionContext: nil, config: config()
        )
        #expect(out.contains { $0.content.contains("active skill:") } == false)
    }

    // MARK: - Async status line

    @Test("Async/background markers emit a status line")
    func asyncStatusLineEmitted() {
        let probe = Message(
            id: UUID(),
            role: .assistant,
            content: "calling schedule_task to run later",
            timestamp: Date(),
            toolCalls: []
        )
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [probe], tail: [], skills: [], instructionContext: nil, config: config()
        )
        #expect(out.contains { $0.content.contains("Async/background tasks") })
    }

    @Test("No async markers => no async status line")
    func noAsyncStatusLine() {
        let probe = Message(id: UUID(), role: .assistant, content: "ordinary turn", timestamp: Date(), toolCalls: [])
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [probe], tail: [], skills: [], instructionContext: nil, config: config()
        )
        #expect(out.contains { $0.content.contains("Async/background tasks") } == false)
    }

    @Test("Disabled re-injection emits nothing")
    func disabledReinjectionEmitsNothing() {
        let cfg = config { $0.compactionReinjectionEnabled = false }
        let messages = fileAccess(path: "f.txt", content: "data", id: "c1")
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: messages, tail: [],
            skills: [ReinjectableSkill(name: "s", content: "body")],
            instructionContext: "[Context reinjection — post-compaction instruction refresh]\nrules",
            config: cfg
        )
        #expect(out.isEmpty)
    }

    // MARK: - Instruction section re-injection

    @Test("Instruction context is injected before file and skill attachments")
    func instructionContextInjected() {
        let context = "[Context reinjection — post-compaction instruction refresh]\nRun startup."
        let messages = fileAccess(path: "f.txt", content: "data", id: "c1")
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: messages, tail: [],
            skills: [ReinjectableSkill(name: "s", content: "skill body")],
            instructionContext: context,
            config: config()
        )
        let instructionIndex = out.firstIndex { $0.content.contains("post-compaction instruction refresh") }
        let fileIndex = out.firstIndex { $0.content.contains("recent file content") }
        let skillIndex = out.firstIndex { $0.content.contains("active skill:") }
        #expect(instructionIndex != nil)
        #expect(fileIndex != nil)
        #expect(skillIndex != nil)
        #expect(instructionIndex! < fileIndex!)
        #expect(instructionIndex! < skillIndex!)
    }

    @Test("Nil instruction context emits no instruction attachment")
    func nilInstructionContextSkipped() {
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [], middle: [], tail: [], skills: [], instructionContext: nil, config: config()
        )
        #expect(out.contains { $0.content.contains("post-compaction instruction refresh") } == false)
    }

    // MARK: - Plan presence (file-backed)

    @Test("plan reinjection emits path when plan.md exists on disk")
    func planReinjectionWhenFileExists() throws {
        let conversationID = UUID()
        defer { _ = AgentPlanStore.removeConversationDirectory(for: conversationID) }
        try AgentPlanStore.ensureConversationDirectory(for: conversationID)
        try "# Plan\n\nhello\n".write(
            to: AgentPlanStore.planURL(for: conversationID),
            atomically: true,
            encoding: .utf8
        )
        let path = AgentPlanStore.planPathString(for: conversationID)
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [],
            middle: [Message(id: UUID(), role: .user, content: "no plan markers", timestamp: Date())],
            tail: [],
            skills: [],
            instructionContext: nil,
            config: config(),
            conversationID: conversationID
        )
        let planMsg = out.first { $0.content.contains("plan.md is active") }
        #expect(planMsg != nil)
        #expect(planMsg?.content.contains(path) == true)
        #expect(planMsg?.content.contains("get_plan") == true)
    }

    @Test("plan reinjection skips transcript mentions when plan.md is absent")
    func planReinjectionIgnoresSubstringWithoutFile() {
        let conversationID = UUID()
        let out = ContextCompactionReinjectionCollector.collectMessages(
            head: [],
            middle: [
                Message(
                    id: UUID(),
                    role: .user,
                    content: "please discuss plan.md and create_plan / get_plan",
                    timestamp: Date()
                ),
            ],
            tail: [],
            skills: [],
            instructionContext: nil,
            config: config(),
            conversationID: conversationID
        )
        #expect(out.contains(where: { $0.content.contains("plan.md is active") }) == false)
    }
}

@Suite("Compaction persistence size guard (CR-F)")
struct ContextCompactionPersistenceGuardTests {
    private func summarizedMiddle(chars: Int) -> [Message] {
        [
            Message(
                id: UUID(),
                role: .assistant,
                content: String(repeating: "z", count: chars),
                timestamp: Date(),
                toolCalls: []
            ),
        ]
    }

    @Test("A ~10k-token summary now passes the persistence ceiling (was rejected at budget x1.5)")
    func summaryPassesUnderRepairedCeiling() {
        var cfg = ContextCompactionConfiguration.default
        cfg.compactionSummaryBudgetTokens = 2_000 // old gate would be 3k tokens
        let middle = summarizedMiddle(chars: 40_000) // ~10k tokens
        let passes = ContextCompactionCheckpointSupport.compactionCheckpointPersistencePassesSizeGuards(
            compactedMiddle: middle,
            config: cfg,
            previousSummaryText: nil,
            kind: .summarized
        )
        #expect(passes)
    }

    @Test("Relative-growth guard still rejects runaway growth vs prior summary")
    func relativeGrowthStillRejects() {
        let cfg = ContextCompactionConfiguration.default
        let middle = summarizedMiddle(chars: 40_000) // ~10k tokens
        let rejected = ContextCompactionCheckpointSupport.compactionCheckpointPersistencePassesSizeGuards(
            compactedMiddle: middle,
            config: cfg,
            previousSummaryText: "tiny prior summary",
            kind: .summarized
        )
        #expect(rejected == false)
    }
}
