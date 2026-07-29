import Foundation
import Testing
@testable import SwiftAgentHarness

/// The built-in explore / plan / general-purpose roles ship enabled, so their capability grants are
/// a shipped security surface rather than operator configuration. These pin the grants themselves.
@Suite("Built-in local agent triad")
struct BuiltInLocalAgentTriadTests {
    private let registry = ModeRegistryService(modeProfileConfiguration: .empty)

    private func profile(_ id: String) async throws -> ResolvedModeProfile {
        try await registry.resolve(modeId: id)
    }

    private func policyContext(_ profile: ResolvedModeProfile) -> ModePolicyContext {
        ModePolicyContext(interactionMode: profile.interactionMode, resolvedProfile: profile)
    }

    @Test("The triad is seeded and every definition points at a resolvable mode profile")
    func triadIsSeededAndResolvable() async throws {
        let definitions = LocalAgentConfiguration.builtInDefaults.definitions
        #expect(definitions.map(\.toolName) == [
            "delegate_explore",
            "delegate_general_purpose",
            "delegate_plan",
        ])
        for definition in definitions {
            // An unresolvable profile would silently un-publish the agent at provider install.
            _ = try await profile(definition.modeProfileID)
        }
    }

    // MARK: - Read-only is enforced at dispatch, not by prompt

    @Test("Explore and plan cannot write, edit, or reach a shell")
    func readOnlyRolesCannotMutate() async throws {
        let policy = ToolPolicyConfiguration.unrestricted
        for id in ["subagent-explore", "subagent-plan"] {
            let context = policyContext(try await profile(id))
            for allowed in ["read_file", "glob", "grep"] {
                #expect(policy.isToolAllowed(name: allowed, context: context), "\(id) should allow \(allowed)")
            }
            // `bash` is the one that matters: redirects and heredocs would make read-only a prompt
            // request rather than a guarantee.
            for denied in ["write_file", "edit_file", "bash", "process"] {
                #expect(policy.isToolAllowed(name: denied, context: context) == false, "\(id) must not allow \(denied)")
            }
        }
    }

    @Test("No built-in role can delegate further")
    func rolesCannotRecurse() async throws {
        for id in ["subagent-explore", "subagent-plan", "subagent-general"] {
            let resolved = try await profile(id)
            #expect(resolved.subAgents.allow == [], "\(id) must deny sub-agent spawning")
        }
    }

    @Test("General purpose keeps the full working surface but is denied the delegate tools")
    func generalPurposeHasFullSurfaceMinusDelegation() async throws {
        let policy = ToolPolicyConfiguration.unrestricted
        let context = policyContext(try await profile("subagent-general"))
        for allowed in ["read_file", "write_file", "edit_file", "bash", "glob", "grep"] {
            #expect(policy.isToolAllowed(name: allowed, context: context), "general purpose should allow \(allowed)")
        }
        #expect(policy.isToolDenied(name: "delegate_explore", context: context))
        #expect(policy.isToolDenied(name: "delegate_general_purpose", context: context))
    }

    // MARK: - The read-only grant must not be widenable by a host

    @Test("Built-in roles are machine profiles, so a host cannot co-author their allow lists")
    func rolesAreMachinePinnedAgainstHostGrants() async throws {
        for id in ["subagent-explore", "subagent-plan", "subagent-general"] {
            let resolved = try await profile(id)
            // Without the machine pin, a config row could set allowsHostGrants:true and a host
            // registering MCP tools with .grant(...) would union them into this profile's allow
            // list — putting a write-capable tool inside a role documented as read-only.
            #expect(resolved.allowsHostGrants == false, "\(id) must refuse host grants")
            #expect(resolved.allowsHostGrantsSource == .machinePinned, "\(id) must be machine-pinned")
            #expect(ConversationLineageInference.machineSubAgentModeProfileIDs.contains(id))
        }
    }

    @Test("An explicit allowsHostGrants opt-in cannot override the machine pin")
    func hostGrantOptInIsIgnoredForRoles() {
        for id in ["subagent-explore", "subagent-plan", "subagent-general"] {
            // Even with an explicit `true` on the row, the machine pin wins — this is the function
            // both the config merge path and ResolvedModeProfile.init route through.
            let resolved = ResolvedModeProfile.resolveAllowsHostGrants(
                id: id,
                explicitOnThisRow: true,
                inherited: nil
            )
            #expect(resolved.value == false, "\(id) must refuse an explicit host-grant opt-in")
            #expect(resolved.source == .machinePinned)
        }
    }

    // MARK: - Directives carry the report contracts the parent relays

    @Test("Each role pins the report shape its caller relays")
    func directivesPinReportShape() async throws {
        let explore = try await profile("subagent-explore").context.modeDirective ?? ""
        #expect(explore.contains("read-only"))
        #expect(explore.contains("line numbers"))

        let plan = try await profile("subagent-plan").context.modeDirective ?? ""
        #expect(plan.contains("Critical Files for Implementation"))

        let general = try await profile("subagent-general").context.modeDirective ?? ""
        #expect(general.contains("concise report"))
        // Status must come from what happened, not from what the delegate meant to do.
        #expect(general.contains("never from what you intended"))
    }

    @Test("Explore omits workspace conventions to keep a narrow role cheap")
    func exploreOmitsWorkspaceConventions() async throws {
        #expect(try await profile("subagent-explore").context.omitWorkspaceConventions == true)
        #expect(try await profile("subagent-explore").context.includeSkills == false)
    }

    // MARK: - Published tool surface

    @Test("The triad publishes three delegate tools the Sub-Agent Pool recognises")
    func triadPublishesDelegateTools() async {
        let provider = InProcessLocalAgentToolProvider(
            definitions: LocalAgentConfiguration.builtInDefaults.definitions
        )
        let tools = await provider.availableTools()
        #expect(tools.count == 3)
        #expect(tools.allSatisfy { $0.name.hasPrefix("delegate_") })
        // All three ship background, so every description must carry the do-not-poll rule.
        #expect(tools.allSatisfy { $0.description.contains("returns a handle immediately") })
        #expect(tools.allSatisfy { $0.description.contains("Do not poll") })
    }
}
