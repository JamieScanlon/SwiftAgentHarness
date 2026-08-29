import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Control-plane sender gate")
struct ControlPlaneSenderGateTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "control-plane-sender",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func conversation() -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "sys",
            interactionMode: .agent
        )
    }

    private func entry(_ name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "d", parameters: [], type: .function),
            source: .local
        )
    }

    private func openProfile() -> ResolvedModeProfile {
        ResolvedModeProfile(
            id: InteractionMode.agent.rawValue,
            interactionMode: .agent,
            assemblyKind: .agentBuild,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: true,
            allowsHostGrants: nil,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
        )
    }

    private func gate(
        toolName: String,
        senderIsOwner: Bool?,
        preApprovedCallBindings: Set<ToolCallApprovalBinding> = []
    ) -> ToolPolicyGatingDecision {
        let conversation = conversation()
        let entry = entry(toolName)
        return DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore()).evaluateCallGating(
            entry: entry,
            call: ToolCallRequest(id: "c1", name: entry.name, arguments: .object([:])),
            conversation: conversation,
            configuration: .init(
                enableTools: true,
                enableAgents: true,
                preApprovedCallBindings: preApprovedCallBindings,
                originSenderIsOwner: senderIsOwner
            ),
            toolPolicy: .unrestricted,
            modePolicyContext: ModePolicyContext(
                conversation: conversation,
                resolvedProfile: openProfile()
            ),
            groupIndex: .empty,
            durableRules: []
        )
    }

    @Test("non-owner is denied a control-plane tool")
    func nonOwnerDenied() {
        let decision = gate(
            toolName: ToolControlPlaneClassification.TriggerTools.scheduleCreate,
            senderIsOwner: false
        )
        #expect(decision.behavior == .deny)
        #expect(decision.reason?.scope == "control-plane-sender")
    }

    /// Read-only listing is control-plane too: a non-owner who cannot register a trigger has no
    /// business enumerating the owner's standing automations either.
    @Test("non-owner is denied the read-only listing as well")
    func nonOwnerDeniedListing() {
        let decision = gate(
            toolName: ToolControlPlaneClassification.TriggerTools.scheduleList,
            senderIsOwner: false
        )
        #expect(decision.behavior == .deny)
        #expect(decision.reason?.scope == "control-plane-sender")
    }

    @Test("owner is not denied by the sender gate")
    func ownerNotDenied() {
        let decision = gate(
            toolName: ToolControlPlaneClassification.TriggerTools.scheduleCreate,
            senderIsOwner: true
        )
        #expect(decision.reason?.scope != "control-plane-sender")
        #expect(decision.behavior != .deny)
    }

    /// `nil` is "no ownership claim", not "not the owner" — CLI, TUI, installer and scheduled fires
    /// all arrive this way, and denying on absence would withhold these tools from every deployment
    /// that is not channel-backed.
    @Test("absent verdict does not deny")
    func nilVerdictDoesNotDeny() {
        let decision = gate(
            toolName: ToolControlPlaneClassification.TriggerTools.scheduleCreate,
            senderIsOwner: nil
        )
        #expect(decision.reason?.scope != "control-plane-sender")
        #expect(decision.behavior != .deny)
    }

    @Test("non-control-plane tools are unaffected by a non-owner sender")
    func ordinaryToolUnaffected() {
        let decision = gate(toolName: "read_file", senderIsOwner: false)
        #expect(decision.reason?.scope != "control-plane-sender")
        #expect(decision.behavior != .deny)
    }

    /// The rung sits at the head of the ladder ahead of `bindingPreApproved`, so an `allow-once`
    /// the owner cleared earlier in the run cannot be reused as a bypass by a different speaker.
    @Test("a pre-approved call binding does not bypass the sender gate")
    func preApprovedBindingDoesNotBypass() {
        let name = ToolControlPlaneClassification.TriggerTools.scheduleCreate
        let binding = ToolCallApprovalBinding(
            toolName: ToolNamePolicyNormalization.canonical(name),
            argumentsFingerprint: ToolCallApprovalBinding.argumentsFingerprint(arguments: .object([:]))
        )
        let decision = gate(
            toolName: name,
            senderIsOwner: false,
            preApprovedCallBindings: [binding]
        )
        #expect(decision.behavior == .deny)
        #expect(decision.reason?.scope == "control-plane-sender")
    }
}

@Suite("Trigger sender ownership verdict")
struct TriggerSenderOwnershipTests {
    private func trigger(
        source: TriggerSource,
        initiator: TriggerInitiatorKind,
        ownershipResolvable: Bool = true
    ) -> HarnessTrigger {
        var metadata: [String: String] = [:]
        if source == .channel, ownershipResolvable {
            metadata["channelOwnershipResolvable"] = "true"
        }
        return HarnessTrigger(
            id: "t1",
            source: source,
            sourceMetadata: metadata,
            payload: "{}",
            payloadFormat: .structured,
            initiator: TriggerInitiator(kind: initiator, id: "sender-1"),
            trust: .knownParty
        )
    }

    @Test("channel trigger from the primary user is the owner")
    func channelUserIsOwner() {
        #expect(TriggerDispatchService.senderIsOwner(
            for: trigger(source: .channel, initiator: .user)
        ) == true)
    }

    @Test("channel trigger from anyone else is not the owner")
    func channelExternalIsNotOwner() {
        #expect(TriggerDispatchService.senderIsOwner(
            for: trigger(source: .channel, initiator: .external)
        ) == false)
    }

    @Test("channel with no primaryUser configured asserts nothing")
    func channelWithoutOwnershipResolutionAssertsNothing() {
        #expect(TriggerDispatchService.senderIsOwner(
            for: trigger(source: .channel, initiator: .user, ownershipResolvable: false)
        ) == nil)
        #expect(TriggerDispatchService.senderIsOwner(
            for: trigger(source: .channel, initiator: .external, ownershipResolvable: false)
        ) == nil)
    }

    /// The load-bearing case: machinery has no sender concept. Mapping a cron fire through
    /// `kind == .user` would stamp `false` on it and deny the owner's own scheduled work.
    @Test("non-channel sources assert nothing regardless of initiator kind")
    func nonChannelSourcesAssertNothing() {
        for source in [TriggerSource.cron, .webhook, .fileEvent, .api, .delegate] {
            for kind in [TriggerInitiatorKind.system, .external, .agent, .user] {
                #expect(TriggerDispatchService.senderIsOwner(
                    for: trigger(source: source, initiator: kind)
                ) == nil)
            }
        }
    }
}
