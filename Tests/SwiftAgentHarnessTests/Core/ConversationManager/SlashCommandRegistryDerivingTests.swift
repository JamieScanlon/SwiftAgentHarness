import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SlashCommandRegistry derived sets and merge")
struct SlashCommandRegistryDerivingTests {

    @Test("Tier sets cover every registered name and alias exactly once across tiers")
    func tierPartitionCoversAllNames() {
        let cmd = SlashCommand(
            base: SlashCommandBase(
                name: "alpha",
                aliases: ["a", "/beta"],
                description: "Test",
                bypassTier: .sideEffectFree
            ),
            kind: .local
        )
        let reg = SlashCommandRegistry(commands: [cmd])
        let all = reg.allClassifiedCommandNames()
        #expect(all == Set(["alpha", "a", "beta"]))

        var seen = Set<String>()
        for tier in SlashCommandBypassTier.allCases {
            let names = reg.commandNames(for: tier)
            for n in names {
                #expect(!seen.contains(n), "Duplicate classification for \(n)")
                seen.insert(n)
            }
        }
        #expect(seen == all)
    }

    @Test("Merged registry includes skill keys and excludes configured names")
    func mergedSkillsAndExclusion() {
        let skills = [
            AvailableSkillInfo(name: "foo-skill", description: "Foo"),
            AvailableSkillInfo(name: "bar-skill", description: "Bar"),
        ]
        let reg = SlashCommandRegistry.merged(
            compactEnabled: true,
            skills: skills,
            excludedSkillAutocompleteNames: ["foo-skill"]
        )
        let names = Set(reg.commands.map { $0.base.name })
        #expect(names.contains("compact"))
        #expect(names.contains("skill:bar-skill"))
        #expect(!names.contains("skill:foo-skill"))
        let ac = reg.autocompleteEntries()
        let slashNames = Set(ac.map(\.name))
        #expect(slashNames.contains("/skill:bar-skill"))
        #expect(!slashNames.contains("/skill:foo-skill"))
    }
}
