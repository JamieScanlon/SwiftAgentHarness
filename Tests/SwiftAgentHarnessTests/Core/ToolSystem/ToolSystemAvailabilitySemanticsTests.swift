import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool System — availability semantics")
struct ToolSystemAvailabilitySemanticsTests {
    private struct FixedExecutionEnvironmentAdapter: ToolExecutionEnvironmentAdapting {
        let id: String = "tool-execution-environment.test"
        let descriptorsByToolName: [String: ToolRegistryEntry.ExecutionEnvironmentDescriptor]

        func descriptor(for entry: ToolRegistryEntry) -> ToolRegistryEntry.ExecutionEnvironmentDescriptor {
            descriptorsByToolName[entry.name] ?? entry.executionEnvironment
        }
    }

    @Test("ToolAvailabilityBlockReason raw values are stable for diagnostics")
    func blockReasonRawValues() {
        #expect(ToolAvailabilityBlockReason.toolsDisabledForSend.rawValue == "toolsDisabledForSend")
        #expect(ToolAvailabilityBlockReason.agentsDisabledForRemoteAgentTool.rawValue == "agentsDisabledForRemoteAgentTool")
        #expect(ToolAvailabilityBlockReason.promptConfigAllowlist.rawValue == "promptConfigAllowlist")
        #expect(ToolAvailabilityBlockReason.promptConfigDenylist.rawValue == "promptConfigDenylist")
        #expect(ToolAvailabilityBlockReason.escalationRequired.rawValue == "escalationRequired")
        #expect(ToolAvailabilityBlockReason.approvalRequired.rawValue == "approvalRequired")
        #expect(ToolAvailabilityBlockReason.executionEnvironmentPolicyDenied.rawValue == "executionEnvironmentPolicyDenied")
        #expect(ToolAvailabilityBlockReason.recursionDepthExceeded.rawValue == "recursionDepthExceeded")
        #expect(ToolAvailabilityBlockReason.hostingRoutingPolicyDenied.rawValue == "hostingRoutingPolicyDenied")
        #expect(ToolAvailabilityBlockReason.routingToolWhitelist.rawValue == "routingToolWhitelist")
        #expect(ToolAvailabilityBlockReason.allCases.count == 10)
    }

    @Test("registry entries classify local mcp a2a and unknown sources deterministically")
    func registryClassification() async {
        let descriptors: [RegisteredToolDescriptor] = [
            makeDescriptor(name: ConversationsToolProvider.listConversationsToolName, source: .local, type: .function),
            makeDescriptor(name: "mcp_search", source: .mcp, type: .mcpTool),
            makeDescriptor(name: "delegate_codegen", source: .a2a, type: .a2aAgent),
            makeDescriptor(name: "other_tool", source: .unknown, type: .function),
        ]
        let entries = OrchestrationToolCatalog.registryEntries(from: descriptors)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.source) })
        let byEnvironment = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.executionEnvironment.kind) })

        #expect(entries.map(\.name) == ["delegate_codegen", "list_conversations", "mcp_search", "other_tool"])
        #expect(byName[ConversationsToolProvider.listConversationsToolName] == .local)
        #expect(byName["mcp_search"] == .mcp)
        #expect(byName["delegate_codegen"] == .a2a)
        #expect(byName["other_tool"] == .unknown)
        #expect(byEnvironment[ConversationsToolProvider.listConversationsToolName] == .local)
        #expect(byEnvironment["mcp_search"] == .mcp)
        #expect(byEnvironment["delegate_codegen"] == .a2a)
        #expect(byEnvironment["other_tool"] == .unknown)
    }

    @Test("registry projection applies execution-environment adapter overrides deterministically")
    func registryProjectionAppliesExecutionEnvironmentAdapterOverrides() async {
        let descriptor = makeDescriptor(name: "mcp_search", source: .mcp, type: .mcpTool)
        let adapter = FixedExecutionEnvironmentAdapter(
            descriptorsByToolName: [
                "mcp_search": .init(
                    kind: .mcp,
                    adapterID: "tool-env.mcp.acp-stdio",
                    isolationLevel: .remoteManaged
                )
            ]
        )
        let entry = OrchestrationToolCatalog.registryEntries(
            from: [descriptor],
            executionEnvironmentAdapter: adapter
        ).first
        #expect(entry?.executionEnvironment.kind == .mcp)
        #expect(entry?.executionEnvironment.adapterID == "tool-env.mcp.acp-stdio")
        #expect(entry?.executionEnvironment.isolationLevel == .remoteManaged)
    }

    @Test("gateway identifies halting tool calls from effective entries")
    func gatewayIdentifiesHaltingToolCalls() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let haltingNames = [
            AgentPlanToolProvider.declareAgentBuildCompleteToolName,
            ModeTransitionToolProvider.exitPlanModeToolName,
            TerminationToolProvider.finishToolName,
            TerminationToolProvider.askUserToolName,
        ]
        let haltingEntries = haltingNames.map {
            ToolRegistryEntry(
                definition: ToolDefinition(name: $0, description: "d", parameters: [], type: .function),
                source: .local
            )
        }
        let nonHaltingEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: AgentPlanToolProvider.getPlanToolName, description: "d", parameters: [], type: .function),
            source: .local
        )
        let thinkEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: TerminationToolProvider.thinkToolName, description: "d", parameters: [], type: .function),
            source: .local
        )
        for haltingName in haltingNames {
            #expect(gateway.isHaltingToolCall(toolName: haltingName, effectiveEntries: haltingEntries))
        }
        #expect(gateway.isHaltingToolCall(toolName: AgentPlanToolProvider.getPlanToolName, effectiveEntries: [nonHaltingEntry]) == false)
        #expect(gateway.isHaltingToolCall(toolName: TerminationToolProvider.thinkToolName, effectiveEntries: [thinkEntry]) == false)
        #expect(
            gateway.isHaltingToolCall(
                toolName: "Finish",
                effectiveEntries: haltingEntries.filter {
                    $0.name == TerminationToolProvider.finishToolName
                }
            )
        )
    }

    @Test("registry entries preserve descriptor planner metadata")
    func registryPlannerMetadataPropagation() async {
        let descriptors: [RegisteredToolDescriptor] = [
            makeDescriptor(
                name: ConversationsToolProvider.listConversationsToolName,
                source: .local,
                type: .function,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
            makeDescriptor(
                name: AgentPlanToolProvider.updatePlanTaskToolName,
                source: .local,
                type: .function,
                effectClass: .mutating,
                parallelHint: .serialOnly
            ),
            makeDescriptor(
                name: "mcp_dynamic",
                source: .mcp,
                type: .mcpTool,
                effectClass: .unknown,
                parallelHint: .unknown
            ),
            makeDescriptor(
                name: "local_unannotated",
                source: .local,
                type: .function,
                effectClass: .unknown,
                parallelHint: .unknown
            ),
        ]
        let entries = OrchestrationToolCatalog.registryEntries(from: descriptors)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName[ConversationsToolProvider.listConversationsToolName]?.effectClass == .readOnly)
        #expect(byName[ConversationsToolProvider.listConversationsToolName]?.parallelHint == .parallelizable)
        #expect(byName[AgentPlanToolProvider.updatePlanTaskToolName]?.effectClass == .mutating)
        #expect(byName[AgentPlanToolProvider.updatePlanTaskToolName]?.parallelHint == .serialOnly)
        #expect(byName["mcp_dynamic"]?.effectClass == .unknown)
        #expect(byName["mcp_dynamic"]?.parallelHint == .unknown)
        #expect(byName["local_unannotated"]?.effectClass == .unknown)
        #expect(byName["local_unannotated"]?.parallelHint == .unknown)
    }

    @Test("registry entries surface normalized schema metadata for API payloads")
    func registrySchemaMetadataPropagation() {
        let definition = ToolDefinition(
            name: "schema_rich_tool",
            description: "tool",
            parameters: [
                .init(name: "query", description: "query", type: "string", required: true),
                .init(name: "limit", description: "limit", type: "integer", required: false),
            ],
            type: .mcpTool
        )
        let source: ToolRegistrationSource = .mcp
        let normalizer = ToolSchemaNormalizer()
        let descriptor = RegisteredToolDescriptor(
            definition: definition,
            source: source,
            effectClass: .unknown,
            parallelHint: .unknown,
            policyTags: [],
            normalizedSchema: normalizer.normalize(rawSchema: definition.inferredSchemaJSON, source: source)
        )
        let entry = OrchestrationToolCatalog.registryEntries(from: [descriptor]).first
        let info = entry?.availableToolInfo
        #expect(info?.normalizedSchemaFingerprint == descriptor.normalizedSchemaFingerprint)
        #expect(info?.normalizedSchemaVersion == descriptor.normalizedSchemaVersion)
        #expect(info?.normalizedTopLevelType == descriptor.schemaSummary.topLevelType)
        #expect(info?.normalizedRequiredCount == descriptor.schemaSummary.requiredCount)
        #expect(info?.normalizedPropertyCount == descriptor.schemaSummary.propertyCount)
    }

    @Test("gateway effective tools enforce allowlist disabled list and agent toggle")
    func gatewayEffectiveToolsFiltering() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .denylist(tools: ["blocked_tool"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "allowed_local", description: "", parameters: [], type: .function),
                source: .local
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_agent", description: "", parameters: [], type: .function),
                source: .a2a
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "blocked_tool", description: "", parameters: [], type: .function),
                source: .local
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "not_allowlisted", description: "", parameters: [], type: .function),
                source: .local
            ),
        ]
        let policy = ToolPolicyConfiguration.unrestricted

        let tools = gateway.effectiveToolsForConversation(
            entries: entries,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(
                    allow: ["allowed_local", "delegate_agent", "blocked_tool"],
                    deny: [],
                    approvalPolicy: nil
                )
            ),
            configuration: .init(enableTools: true, enableAgents: false),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(tools.map(\.name) == ["allowed_local"])
    }

    @Test("gateway available tools for API match effective entries for conversation")
    func gatewayAPIToolsMatchEffectiveEntries() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .denylist(tools: ["blocked_tool"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "allowed_local", description: "", parameters: [], type: .function),
                source: .local
            ),
            ToolRegistryEntry(
                definition: ToolDefinition(name: "blocked_tool", description: "", parameters: [], type: .function),
                source: .local
            ),
        ]
        let policy = ToolPolicyConfiguration.unrestricted
        let modeCtx = testModePolicyContext(
            for: conversation,
            tools: ModeProfileToolsSlice(
                allow: ["allowed_local", "blocked_tool"],
                deny: [],
                approvalPolicy: nil
            )
        )
        let configuration = AgentRuntimeTurnConfiguration(
            managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
        )
        let apiTools = gateway.availableToolsForAPI(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: configuration,
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        let effective = gateway.effectiveEntriesForConversation(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: configuration,
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(apiTools.map(\.name) == effective.map(\.name))
        #expect(apiTools.map(\.name) == ["allowed_local"])
    }

    @Test("gateway available tools for API exclude tools when enableTools is false")
    func gatewayAPIToolsRespectEnableToolsFlag() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "allowed_local", description: "", parameters: [], type: .function),
                source: .local
            ),
        ]
        let policy = ToolPolicyConfiguration.unrestricted
        let modeCtx = testModePolicyContext(for: conversation)
        let configuration = AgentRuntimeTurnConfiguration(
            managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: false, enableAgents: true)
        )
        let apiTools = gateway.availableToolsForAPI(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: configuration,
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(apiTools.isEmpty)
    }

    @Test("gateway available tools for API include approval-gated tools")
    func gatewayAPIToolsIncludeApprovalGated() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let toolName = "gated_tool"
        let entries: [ToolRegistryEntry] = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: toolName, description: "", parameters: [], type: .function),
                source: .local
            ),
        ]
        let policy = ToolPolicyConfiguration(approvalRequiredToolNames: [toolName])
        let modeCtx = testModePolicyContext(for: conversation)
        let configuration = AgentRuntimeTurnConfiguration(
            managerConfiguration: HarnessRuntimeSession.Configuration(enableTools: true, enableAgents: true)
        )
        let apiTools = gateway.availableToolsForAPI(
            entries: entries,
            conversation: conversation,
            modePolicyContext: modeCtx,
            configuration: configuration,
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(apiTools.map(\.name) == [toolName])
    }

    @Test("gateway denylist takes precedence over allowlist")
    func gatewayDenylistPrecedence() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "dangerous_tool", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration()
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: ["dangerous_tool"], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .promptConfigDenylist)
    }

    @Test("gateway escalation-required tools are blocked without elevated config")
    func gatewayEscalationRequired() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "filesystem_write", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration(
            escalationRequiredToolNames: ["filesystem_write"]
        )
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true, allowEscalatedTools: false),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .escalationRequired)
    }

    @Test("gateway approval-required tools are blocked unless pre-approved")
    func gatewayApprovalRequired() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "filesystem_write", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration(
            approvalRequiredToolNames: ["filesystem_write"]
        )
        let blocked = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(blocked.allowed == false)
        #expect(blocked.blockReason == .approvalRequired)
        #expect(blocked.isAdvertisedToModel == true)
        let advertisedEntries = gateway.effectiveEntriesForConversation(
            entries: [entry],
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(advertisedEntries.map(\.name) == ["filesystem_write"])
        let allowed = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true, preApprovedToolNames: ["filesystem_write"]),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(allowed.allowed == true)
        #expect(allowed.approvalGranted == true)
    }

    @Test("gateway does not statically gate per-call elevated tools")
    func gatewayPerCallElevatedNotGated() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration(
            elevatedToolNames: ["bash"],
            perCallElevatedToolNames: ["bash"]
        )
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == true)
        #expect(decision.isElevated == false)
        #expect(decision.blockReason == nil)
    }

    @Test("gateway still gates statically elevated tools not marked per-call")
    func gatewayStaticElevatedStillGated() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "privileged_tool", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration(
            elevatedToolNames: ["privileged_tool"]
        )
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.isElevated == true)
        #expect(decision.blockReason == .approvalRequired)
    }

    @Test("gateway environment policy can deny execution by environment kind")
    func gatewayExecutionEnvironmentPolicyDenied() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let mcpEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "remote_search", description: "", parameters: [], type: .mcpTool),
            source: .mcp
        )
        let policy = ToolPolicyConfiguration(
            executionEnvironmentPolicy: .init(disallowed: [.mcp])
        )
        let decision = gateway.evaluateAvailability(
            entry: mcpEntry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .executionEnvironmentPolicyDenied)
    }

    @Test("gateway environment policy can deny execution by adapter id")
    func gatewayExecutionEnvironmentAdapterPolicyDenied() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "local_runner", description: "", parameters: [], type: .function),
            source: .local,
            executionEnvironment: .init(
                kind: .local,
                adapterID: "tool-env.local.restricted",
                isolationLevel: .inProcess
            )
        )
        let policy = ToolPolicyConfiguration(
            executionEnvironmentPolicy: .init(disallowedAdapterIDs: ["tool-env.local.restricted"])
        )
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .executionEnvironmentPolicyDenied)
    }

    @Test("delegate tools require approval on user route")
    func gatewayDelegateApprovalRoute() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let localTool = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_local", description: "", parameters: [], type: .function),
            source: .local
        )
        let a2aDelegate = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_remote", description: "", parameters: [], type: .a2aAgent),
            source: .a2a
        )
        let classifier = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        let basePolicy = ToolPolicyConfiguration.unrestricted

        let localDecision = gateway.evaluateAvailability(
            entry: localTool,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: basePolicy,
            trustPolicy: .disabled,
            subAgentToolClassifier: classifier
        )
        #expect(localDecision.approvalRoute == .parent)

        let remoteDecision = gateway.evaluateAvailability(
            entry: a2aDelegate,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: basePolicy,
            trustPolicy: .disabled,
            subAgentToolClassifier: classifier
        )
        #expect(remoteDecision.allowed == false)
        #expect(remoteDecision.blockReason == .approvalRequired)
        #expect(remoteDecision.approvalRoute == .user)
    }

    @Test("delegate tools are blocked when recursion depth is exhausted")
    func gatewayDelegateRecursionDepthLimit() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            metadata: .object(["subAgentDepth": .double(4)]),
            parentConversationID: UUID()
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let a2aDelegate = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_remote", description: "", parameters: [], type: .a2aAgent),
            source: .a2a
        )
        let classifier = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        let basePolicy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: a2aDelegate,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: basePolicy,
            trustPolicy: .disabled,
            subAgentToolClassifier: classifier
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == ToolAvailabilityBlockReason.recursionDepthExceeded)
    }

    @Test("delegate tools are blocked by hosting/routing policy mismatch")
    func gatewayHostingRoutingPolicyDenied() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            metadata: .object([
                "subAgentHostPersonaID": .string("research-agent"),
                "subAgentAuthScopeTags": .array([.string("web:read")]),
                "subAgentRoutingDomain": .string("research"),
                "subAgentTenantScope": .string("default"),
            ])
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let delegate = ToolRegistryEntry(
            definition: ToolDefinition(name: "Coding Agent", description: "", parameters: [], type: .a2aAgent),
            source: .a2a
        )
        let configuration = try! HarnessConversationTestFixtures.promptConfigFixture()
        let classifier = DefaultSubAgentPool(
            hostingPolicyConfiguration: configuration.subAgentHostingPolicy
        )
        let policy = configuration.toolPolicy
        let decision = gateway.evaluateAvailability(
            entry: delegate,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: classifier
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .hostingRoutingPolicyDenied)
    }

    @Test("delegate tools are blocked when mode sub-agent allow-list excludes them")
    func gatewayModeSubAgentAllowListDenied() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let delegate = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_remote", description: "", parameters: [], type: .a2aAgent),
            source: .a2a
        )
        let classifier = DefaultSubAgentPool(hostingPolicyConfiguration: .empty)
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: delegate,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                subAgents: ModeProfileSubAgentsSlice(
                    allow: ["Coding Agent"],
                    maxDepth: nil,
                    childModeOnSpawnProfileId: nil
                )
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: classifier
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .hostingRoutingPolicyDenied)
    }

    @Test("dispatch contract disables parallel only for unknown static metadata")
    func dispatchPlannerConservativeFallback() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true
        )
        let readOnlyEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "list_conversations", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .parallelizable
        )
        let mutatingEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "update_plan_task", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let bashEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let unknownEntry = ToolRegistryEntry(
            definition: ToolDefinition(name: "remote_dynamic", description: "", parameters: [], type: .function),
            source: .mcp,
            effectClass: .unknown,
            parallelHint: .unknown
        )
        let pureContract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry])
        #expect(pureContract.parallelDispatchEnabled == true)
        #expect(pureContract.dispatchPlannerMode == .mixedDeterministic)
        let mutatingContract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry, mutatingEntry])
        #expect(mutatingContract.parallelDispatchEnabled == true)
        #expect(mutatingContract.dispatchPlannerMode == .mixedDeterministic)
        let bashContract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry, bashEntry])
        #expect(bashContract.parallelDispatchEnabled == true)
        let unknownContract = gateway.dispatchContract(from: policy, effectiveEntries: [readOnlyEntry, unknownEntry])
        #expect(unknownContract.parallelDispatchEnabled == false)
    }

    @Test("dispatch contract planner keeps empty effective set conservative")
    func dispatchPlannerEmptySetConservative() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true
        )
        let contract = gateway.dispatchContract(from: policy, effectiveEntries: [])
        #expect(contract.parallelDispatchEnabled == false)
    }

    @Test("dispatch contract carries configured planner mode")
    func dispatchContractPlannerModePropagation() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true,
            dispatchPlannerMode: .mixedDeterministic
        )
        let contract = gateway.dispatchContract(from: policy, effectiveEntries: [])
        #expect(contract.dispatchPlannerMode == .mixedDeterministic)
    }

    @Test("routing tool allowlist blocks tools not in whitelist")
    func gatewayRoutingToolAllowlistBlocks() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .allowlist(tools: ["read_file", "search"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "write_file", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .routingToolWhitelist)
    }

    @Test("routing tool allowlist permits tools in whitelist")
    func gatewayRoutingToolAllowlistPermits() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .allowlist(tools: ["read_file", "search"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == true)
    }

    @Test("routing allowlist permits legacy alias for canonical tool")
    func gatewayRoutingAllowlistLegacyAlias() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .allowlist(tools: ["read"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local
        )
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == true)
    }

    @Test("preApproved legacy grant approves canonical tool name")
    func preApprovedLegacyGrantApprovesCanonical() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .chat
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration(approvalRequiredToolNames: ["read_file"])
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(for: conversation),
            configuration: .init(
                enableTools: true,
                enableAgents: true,
                preApprovedToolNames: ["read"]
            ),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == true)
        #expect(decision.approvalGranted == true)
    }

    @Test("routing tool denylist blocks listed tools")
    func gatewayRoutingToolDenylistBlocks() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .denylist(tools: ["dangerous_cmd"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "dangerous_cmd", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .routingToolWhitelist)
    }

    @Test("nil routing prefs does not restrict tools")
    func gatewayNilRoutingPrefsUnrestricted() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "any_tool", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == true)
    }

    @Test("nil explicit routing policy does not restrict tools")
    func gatewayNilExplicitRoutingPolicyUnrestricted() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(explicitToolPolicy: nil)
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "any_tool", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == true)
    }

    @Test("mode profile allow intersects with routing whitelist")
    func gatewayModeAllowIntersectsRoutingWhitelist() {
        let model = makeToolsModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            systemPrompt: "sys",
            interactionMode: .agent,
            routingPrefs: ConversationRoutingPrefs(
                explicitToolPolicy: .allowlist(tools: ["read_file"], skills: [])
            )
        )
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "write_file", description: "", parameters: [], type: .function),
            source: .local
        )
        let policy = ToolPolicyConfiguration.unrestricted
        let decision = gateway.evaluateAvailability(
            entry: entry,
            conversation: conversation,
            modePolicyContext: testModePolicyContext(
                for: conversation,
                tools: ModeProfileToolsSlice(allow: ["read_file", "write_file"], deny: [], approvalPolicy: nil)
            ),
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: policy,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil
        )
        #expect(decision.allowed == false)
        #expect(decision.blockReason == .routingToolWhitelist)
    }

    @Test("dispatch contract matrix enables parallel unless static metadata is unknown")
    func dispatchContractPureOnlyMatrix() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let policy = ToolPolicyConfiguration(
            parallelDispatchEnabled: true
        )
        let tuples: [(ToolRegistryEntry.EffectClass, ToolRegistryEntry.ParallelHint, Bool)] = [
            (.readOnly, .parallelizable, true),
            (.readOnly, .serialOnly, true),
            (.readOnly, .unknown, false),
            (.mutating, .parallelizable, true),
            (.mutating, .serialOnly, true),
            (.mutating, .unknown, false),
            (.unknown, .parallelizable, false),
            (.unknown, .serialOnly, false),
            (.unknown, .unknown, false),
        ]

        for (effectClass, parallelHint, expected) in tuples {
            let entry = ToolRegistryEntry(
                definition: ToolDefinition(
                    name: "tuple_\(effectClass.rawValue)_\(parallelHint.rawValue)",
                    description: "",
                    parameters: [],
                    type: .function
                ),
                source: .local,
                effectClass: effectClass,
                parallelHint: parallelHint
            )
            let contract = gateway.dispatchContract(from: policy, effectiveEntries: [entry])
            #expect(
                contract.parallelDispatchEnabled == expected,
                "unexpected parallel eligibility for \(effectClass.rawValue)/\(parallelHint.rawValue)"
            )
        }
    }

    @Test("evaluateCallAvailability defers sideEffects approval for read-only bash")
    func evaluateCallAvailabilityReadOnlyBash() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let conversation = ModelConversation(id: UUID(), model: makeToolsModel(), systemPrompt: "s")
        let context = testModePolicyContext(
            for: conversation,
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: .sideEffects)
        )
        let call = ToolCallRequest(
            id: "c1",
            name: "bash",
            arguments: .object(["command": .string("ls")])
        )
        let decision = gateway.evaluateCallAvailability(
            entry: entry,
            call: call,
            conversation: conversation,
            modePolicyContext: context,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            groupIndex: .empty
        )
        #expect(decision.allowed)
    }

    @Test("evaluateCallAvailability requires approval for mutating bash under sideEffects")
    func evaluateCallAvailabilityMutatingBashRequiresApproval() {
        let gateway = DefaultToolSystemGateway(visibilityGrants: ToolVisibilityGrantStore())
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly
        )
        let conversation = ModelConversation(id: UUID(), model: makeToolsModel(), systemPrompt: "s")
        let context = testModePolicyContext(
            for: conversation,
            tools: ModeProfileToolsSlice(allow: ["*"], deny: [], approvalPolicy: .sideEffects)
        )
        let call = ToolCallRequest(
            id: "c1",
            name: "bash",
            arguments: .object(["command": .string("rm x")])
        )
        let decision = gateway.evaluateCallAvailability(
            entry: entry,
            call: call,
            conversation: conversation,
            modePolicyContext: context,
            configuration: .init(enableTools: true, enableAgents: true),
            toolPolicy: .unrestricted,
            trustPolicy: .disabled,
            subAgentToolClassifier: nil,
            groupIndex: .empty
        )
        #expect(decision.blockReason == .approvalRequired)
    }

    private func testModePolicyContext(
        for conversation: ModelConversation,
        tools: ModeProfileToolsSlice? = nil,
        subAgents: ModeProfileSubAgentsSlice? = nil
    ) -> ModePolicyContext {
        var resolved = ResolvedModeProfile.builtIn(for: conversation.interactionMode)
        if let tools {
            resolved.tools = tools
        }
        if let subAgents {
            resolved.subAgents = subAgents
        }
        return ModePolicyContext(conversation: conversation, resolvedProfile: resolved)
    }

    private func makeToolsModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "tool-system-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func makeDescriptor(
        name: String,
        source: ToolRegistrationSource,
        type: ToolDefinition.ToolType,
        effectClass: ToolEffectClass = .unknown,
        parallelHint: ToolExecutionParallelHint = .unknown
    ) -> RegisteredToolDescriptor {
        let definition = ToolDefinition(name: name, description: "\(name)-description", parameters: [], type: type)
        let normalizer = ToolSchemaNormalizer()
        let normalized = normalizer.normalize(rawSchema: definition.inferredSchemaJSON, source: source)
        return RegisteredToolDescriptor(
            definition: definition,
            source: source,
            effectClass: effectClass,
            parallelHint: parallelHint,
            policyTags: [],
            normalizedSchema: normalized
        )
    }
}
