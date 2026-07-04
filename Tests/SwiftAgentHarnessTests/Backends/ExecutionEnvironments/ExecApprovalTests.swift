import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

private func execApprovalTestScope(
    conversationID: UUID = UUID(),
    ownerAccountID: UUID? = nil
) -> ExecApprovalScope {
    ExecApprovalScope(conversationID: conversationID, ownerAccountID: ownerAccountID)
}

private func resolveExecApproval(
    store: ExecApprovalStore,
    id: String,
    scope: ExecApprovalScope,
    approved: Bool,
    durable: Bool = false,
    reason: String? = nil,
    strictTenancy: Bool = false,
    ownerScope: UUID? = nil
) async -> ExecApprovalResolution? {
    await store.resolve(
        id: id,
        scope: scope,
        strictTenancy: strictTenancy,
        ownerScope: ownerScope,
        approved: approved,
        durable: durable,
        reason: reason
    )
}

@Suite("Exec approval store and delivery")
struct ExecApprovalTests {
    @Test("resolve wakes waiters with approved resolution")
    func resolveWakesWaiters() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        await store.registerPending(id: "abc", command: "rm -rf /", scope: scope)
        async let waited = store.waitForResolution(id: "abc", timeoutSeconds: 5)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolution = await resolveExecApproval(store: store, id: "abc", scope: scope, approved: true)
        #expect(resolution == .approved(durable: false))
        #expect(await waited == .approved(durable: false))
    }

    @Test("resolve returns nil for unknown id")
    func resolveUnknownID() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        #expect(await resolveExecApproval(store: store, id: "missing", scope: scope, approved: true) == nil)
    }

    @Test("resolve returns nil for cross-conversation scope")
    func resolveRejectsCrossConversationScope() async {
        let store = ExecApprovalStore()
        let ownerA = UUID()
        let convA = UUID()
        let convB = UUID()
        let scopeA = execApprovalTestScope(conversationID: convA, ownerAccountID: ownerA)
        await store.registerPending(id: "cross-1", command: "git push", scope: scopeA)
        let wrongConversation = execApprovalTestScope(conversationID: convB, ownerAccountID: ownerA)
        #expect(
            await resolveExecApproval(
                store: store,
                id: "cross-1",
                scope: wrongConversation,
                approved: true
            ) == nil
        )
    }

    @Test("resolve returns nil for cross-owner scope under strict tenancy")
    func resolveRejectsCrossOwnerScopeUnderStrictTenancy() async {
        let store = ExecApprovalStore()
        let ownerA = UUID()
        let ownerB = UUID()
        let conv = UUID()
        let scopeA = execApprovalTestScope(conversationID: conv, ownerAccountID: ownerA)
        await store.registerPending(id: "tenant-1", command: "git push", scope: scopeA)
        #expect(
            await resolveExecApproval(
                store: store,
                id: "tenant-1",
                scope: scopeA,
                approved: true,
                strictTenancy: true,
                ownerScope: ownerB
            ) == nil
        )
        #expect(
            await resolveExecApproval(
                store: store,
                id: "tenant-1",
                scope: scopeA,
                approved: true,
                strictTenancy: true,
                ownerScope: ownerA
            ) == .approved(durable: false)
        )
    }

    @Test("durable approval pre-approves commands by command name")
    func durableApproval() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        await store.registerPending(id: "abc", command: "git push", scope: scope)
        _ = await resolveExecApproval(store: store, id: "abc", scope: scope, approved: true, durable: true)
        #expect(await store.isDurableApproved(command: "git push"))
        // Same command name with different args is now approved.
        #expect(await store.isDurableApproved(command: "git status --short"))
        #expect(await store.isDurableApproved(command: "  git pull  "))
        // A different command name is not approved.
        #expect(await store.isDurableApproved(command: "npm test") == false)
    }

    @Test("commandName extracts the first executable token")
    func commandNameExtraction() {
        #expect(ExecApprovalStore.commandName(from: "git push origin main") == "git")
        #expect(ExecApprovalStore.commandName(from: "  npm   test ") == "npm")
        #expect(ExecApprovalStore.commandName(from: "ls\t-la") == "ls")
        #expect(ExecApprovalStore.commandName(from: "echo\nhi") == "echo")
        #expect(ExecApprovalStore.commandName(from: "   ") == nil)
        #expect(ExecApprovalStore.commandName(from: "") == nil)
    }

    @Test("durableGrantCommandName keeps plain command-name grants")
    func durableGrantCommandNamePlainCommands() {
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "git push origin main") == "git")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "  npm   test ") == "npm")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "ls\t-la") == "ls")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "echo\nhi") == "echo")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "   ") == nil)
    }

    @Test("durableGrantCommandName peels shell interpreters to inner command")
    func durableGrantCommandNameShellPeeling() {
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "bash -lc 'ls -la'") == "ls")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "bash -c \"git push\"") == "git")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "/bin/bash -- -lc 'npm test'") == "npm")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "sh -c 'echo hi'") == "echo")
    }

    @Test("durableGrantCommandName peels env and prefix wrappers")
    func durableGrantCommandNameWrapperPeeling() {
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "env FOO=bar git push") == "git")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "sudo npm test") == "npm")
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "nice -n 10 git status") == "git")
    }

    @Test("durableGrantCommandName fails closed for unpeelable interpreters")
    func durableGrantCommandNameFailClosed() {
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "bash") == nil)
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "bash -lc") == nil)
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "bash script.sh") == nil)
        #expect(ExecApprovalGrantCommandName.durableGrantCommandName(from: "xargs") == nil)
    }

    @Test("durable approval of bash -lc keys on inner command not bash")
    func durableApprovalShellInterpreterPeeling() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        await store.registerPending(id: "shell-1", command: "bash -lc 'ls -la'", scope: scope)
        _ = await resolveExecApproval(store: store, id: "shell-1", scope: scope, approved: true, durable: true)
        #expect(await store.isDurableApproved(command: "ls -l"))
        #expect(await store.isDurableApproved(command: "bash -lc 'rm -rf /'") == false)
        #expect(await store.listDurableGrants() == ["ls"])
    }

    @Test("durable approval of bash -lc git grants git cross-argument access")
    func durableApprovalShellInterpreterGitCrossArg() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        await store.registerPending(id: "shell-git", command: "bash -c \"git push origin main\"", scope: scope)
        _ = await resolveExecApproval(store: store, id: "shell-git", scope: scope, approved: true, durable: true)
        #expect(await store.isDurableApproved(command: "git status --short"))
        #expect(await store.isDurableApproved(command: "bash -lc 'git pull'"))
    }

    @Test("durable approval of bare bash does not persist a grant")
    func durableApprovalBareBashNoGrant() async {
        let grants = InMemoryExecApprovalGrantStore()
        let store = ExecApprovalStore(grantStore: grants)
        let scope = execApprovalTestScope()
        await store.registerPending(id: "bare-bash", command: "bash", scope: scope)
        let resolution = await resolveExecApproval(store: store, id: "bare-bash", scope: scope, approved: true, durable: true)
        #expect(resolution == .approved(durable: true))
        #expect(await grants.list() == [])
        #expect(await store.isDurableApproved(command: "bash -lc 'ls'") == false)
    }

    @Test("elevated allow-always does not persist durable grant")
    func elevatedAllowAlwaysDoesNotPersistGrant() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        await store.registerPending(id: "elevated-git", command: "git status", scope: scope, allowsDurableBypass: false)
        let resolution = await resolveExecApproval(store: store, id: "elevated-git", scope: scope, approved: true, durable: true)
        #expect(resolution == .approved(durable: true))
        #expect(await store.listDurableGrants() == [])
        #expect(await store.isDurableApproved(command: "git push") == false)
    }

    @Test("delivery skips durable lookup when bypass disallowed")
    func deliverySkipsDurableLookupWhenBypassDisallowed() async {
        let grants = InMemoryExecApprovalGrantStore(commandNames: ["curl"])
        let store = ExecApprovalStore(grantStore: grants)
        let scope = execApprovalTestScope()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        let request = ExecApprovalRequest(
            id: "req-no-bypass",
            command: "curl https://example.com",
            title: "Exec approval",
            description: "curl https://example.com",
            allowsDurableBypass: false
        )
        async let result = delivery.requestApproval(request, headless: false)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolved = await resolveExecApproval(store: store, id: "req-no-bypass", scope: scope, approved: true)
        #expect(resolved == .approved(durable: false))
        #expect(await result == .approved)
    }

    @Test("in-memory grant store add/remove/list/isGranted")
    func inMemoryGrantStore() async {
        let grants = InMemoryExecApprovalGrantStore()
        #expect(await grants.isGranted(commandName: "git") == false)
        await grants.add(commandName: "git")
        await grants.add(commandName: "npm")
        await grants.add(commandName: "git")
        #expect(await grants.isGranted(commandName: "git"))
        #expect(await grants.list() == ["git", "npm"])
        await grants.remove(commandName: "git")
        #expect(await grants.isGranted(commandName: "git") == false)
        #expect(await grants.list() == ["npm"])
    }

    @Test("resolve durable persists through injected grant store")
    func resolveDurablePersistsToInjectedStore() async {
        let grants = InMemoryExecApprovalGrantStore()
        let store = ExecApprovalStore(grantStore: grants)
        let scope = execApprovalTestScope()
        await store.registerPending(id: "abc", command: "git push origin main", scope: scope)
        _ = await resolveExecApproval(store: store, id: "abc", scope: scope, approved: true, durable: true)
        #expect(await grants.isGranted(commandName: "git"))
        #expect(await grants.list() == ["git"])
        #expect(await store.isDurableApproved(command: "git log"))
    }

    @Test("listDurableGrants returns sorted command names from grant store")
    func listDurableGrants() async {
        let grants = InMemoryExecApprovalGrantStore(commandNames: ["npm", "git", "grep"])
        let store = ExecApprovalStore(grantStore: grants)
        #expect(await store.listDurableGrants() == ["git", "grep", "npm"])
    }

    @Test("revokeDurableGrant removes an existing grant")
    func revokeDurableGrantExisting() async {
        let grants = InMemoryExecApprovalGrantStore(commandNames: ["git", "npm"])
        let store = ExecApprovalStore(grantStore: grants)
        #expect(await store.revokeDurableGrant(commandName: "git"))
        #expect(await store.listDurableGrants() == ["npm"])
        #expect(await store.isDurableApproved(command: "git push") == false)
    }

    @Test("revokeDurableGrant trims whitespace before matching")
    func revokeDurableGrantTrimsWhitespace() async {
        let grants = InMemoryExecApprovalGrantStore(commandNames: ["git"])
        let store = ExecApprovalStore(grantStore: grants)
        #expect(await store.revokeDurableGrant(commandName: "  git  "))
        #expect(await store.listDurableGrants() == [])
    }

    @Test("revokeDurableGrant returns false for unknown or blank names")
    func revokeDurableGrantUnknown() async {
        let grants = InMemoryExecApprovalGrantStore(commandNames: ["git"])
        let store = ExecApprovalStore(grantStore: grants)
        #expect(await store.revokeDurableGrant(commandName: "npm") == false)
        #expect(await store.revokeDurableGrant(commandName: "   ") == false)
        #expect(await store.revokeDurableGrant(commandName: "") == false)
        #expect(await store.listDurableGrants() == ["git"])
    }

    @Test("configure swaps the backing grant store")
    func configureSwapsGrantStore() async {
        let store = ExecApprovalStore()
        let seeded = InMemoryExecApprovalGrantStore(commandNames: ["git"])
        await store.configure(grantStore: seeded)
        #expect(await store.isDurableApproved(command: "git push"))
        #expect(await store.isDurableApproved(command: "npm test") == false)
    }

    @Test("pre-seeded grant store pre-approves through default delivery")
    func preSeededGrantStorePreApproves() async {
        let grants = InMemoryExecApprovalGrantStore(commandNames: ["curl"])
        let store = ExecApprovalStore(grantStore: grants)
        let scope = execApprovalTestScope()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        let request = ExecApprovalRequest(
            id: "req-seed",
            command: "curl https://example.com",
            title: "Exec approval",
            description: "curl https://example.com"
        )
        let result = await delivery.requestApproval(request, headless: false)
        #expect(result == .approved)
    }

    @Test("default delivery waits for resolution")
    func defaultDeliveryWaitsForResolution() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope, waitTimeoutSeconds: 5)
        let request = ExecApprovalRequest(
            id: "req-1",
            command: "curl example.com",
            title: "Exec approval",
            description: "curl example.com"
        )
        async let result = delivery.requestApproval(request, headless: false)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolved = await resolveExecApproval(store: store, id: "req-1", scope: scope, approved: true)
        #expect(resolved == .approved(durable: false))
        #expect(await result == .approved)
    }

    @Test("default delivery waits indefinitely by default and resolves on approval")
    func defaultDeliveryIndefiniteWaitsForResolution() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope)
        let request = ExecApprovalRequest(
            id: "req-indef",
            command: "curl example.com",
            title: "Exec approval",
            description: "curl example.com"
        )
        async let result = delivery.requestApproval(request, headless: false)
        // Wait well past any legacy finite timeout to prove it does not self-deny.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await resolveExecApproval(store: store, id: "req-indef", scope: scope, approved: true) == .approved(durable: false))
        #expect(await result == .approved)
    }

    @Test("cancelling an indefinite request denies as cancelled and fires onCleared")
    func defaultDeliveryCancelClears() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        let cleared = ClearedRecorder()
        let delivery = DefaultExecApprovalDelivery(
            store: store,
            approvalScope: scope,
            onCleared: { id in await cleared.record(id) }
        )
        let request = ExecApprovalRequest(
            id: "req-cancel",
            command: "rm -rf /",
            title: "Exec approval",
            description: "rm -rf /"
        )
        let task = Task { await delivery.requestApproval(request, headless: false) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let result = await task.value
        #expect(result == .denied("exec approval cancelled"))
        #expect(await cleared.ids == ["req-cancel"])
    }

    @Test("headless request denies immediately without registering")
    func headlessDeniesImmediately() async {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        let delivery = DefaultExecApprovalDelivery(store: store, approvalScope: scope)
        let request = ExecApprovalRequest(
            id: "req-headless",
            command: "curl example.com",
            title: "Exec approval",
            description: "curl example.com"
        )
        let result = await delivery.requestApproval(request, headless: true)
        guard case .headlessDenied = result else {
            Issue.record("expected headlessDenied, got \(result)")
            return
        }
    }

    @Test("channel delivery still times out at its finite default")
    func channelDeliveryTimesOut() async {
        let listener = MockChannelListener(
            id: .discord,
            config: ChannelListenerConfig(
                enabled: true,
                transport: .mock,
                platformIdentity: "test-bot",
                dmScope: .perChannelPeer
            ),
            logger: Logger(label: "test")
        )
        let outbound = DefaultChannelOutboundAdapter(listener: listener, chunkLimit: 4000)
        let route = ExecApprovalPluginRoute(
            approval: ChannelApprovalCapabilityAdapter(outbound: outbound),
            outbound: outbound,
            target: ChannelDeliveryTarget(chatId: "chat-1", threadId: nil, replyToMessageId: nil)
        )
        let delivery = PluginChannelExecApprovalDelivery(
            store: ExecApprovalStore(),
            approvalScope: execApprovalTestScope(),
            route: route,
            waitTimeoutSeconds: 0.02
        )
        let request = ExecApprovalRequest(
            id: "timeout-1",
            command: "npm test",
            title: "Exec approval",
            description: "npm test"
        )
        let result = await delivery.requestApproval(request, headless: false)
        guard case .deferred = result else {
            Issue.record("expected deferred on timeout, got \(result)")
            return
        }
    }

    @Test("channel delivery posts approval card to mock listener")
    func channelDeliveryPostsCard() async throws {
        let store = ExecApprovalStore()
        let scope = execApprovalTestScope()
        let listener = MockChannelListener(
            id: .discord,
            config: ChannelListenerConfig(
                enabled: true,
                transport: .mock,
                platformIdentity: "test-bot",
                dmScope: .perChannelPeer
            ),
            logger: Logger(label: "test")
        )
        let outbound = DefaultChannelOutboundAdapter(listener: listener, chunkLimit: 4000)
        let route = ExecApprovalPluginRoute(
            approval: ChannelApprovalCapabilityAdapter(outbound: outbound),
            outbound: outbound,
            target: ChannelDeliveryTarget(chatId: "chat-1", threadId: "thread-1", replyToMessageId: nil)
        )
        let delivery = PluginChannelExecApprovalDelivery(store: store, approvalScope: scope, route: route, waitTimeoutSeconds: 0.05)
        let request = ExecApprovalRequest(
            id: "card-1",
            command: "npm test",
            title: "Exec approval",
            description: "npm test"
        )
        async let approval = delivery.requestApproval(request, headless: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = await resolveExecApproval(store: store, id: "card-1", scope: scope, approved: true)
        let result = await approval
        #expect(result == .approved)
        let messages = listener.sentMessages
        #expect(messages.count == 1)
        #expect(messages[0].chatId == "chat-1")
        #expect(messages[0].threadId == "thread-1")
        #expect(messages[0].approvalCard?.approvalID == "card-1")
        #expect(messages[0].approvalCard?.command == "npm test")
    }

    @Test("sendFollowup posts result to channel")
    func sendFollowupPostsResult() async {
        let listener = MockChannelListener(
            id: .slack,
            config: ChannelListenerConfig(
                enabled: true,
                transport: .mock,
                platformIdentity: "test-bot",
                dmScope: .perChannelPeer
            ),
            logger: Logger(label: "test")
        )
        let outbound = DefaultChannelOutboundAdapter(listener: listener, chunkLimit: 4000)
        let route = ExecApprovalPluginRoute(
            approval: ChannelApprovalCapabilityAdapter(outbound: outbound),
            outbound: outbound,
            target: ChannelDeliveryTarget(chatId: "c1", threadId: nil, replyToMessageId: nil)
        )
        let delivery = PluginChannelExecApprovalDelivery(
            store: ExecApprovalStore(),
            approvalScope: execApprovalTestScope(),
            route: route
        )
        await delivery.sendFollowup(approvalID: "x", approved: true)
        #expect(listener.sentMessages.count == 1)
        #expect(listener.sentMessages[0].text.contains("approved"))
    }
}

private actor ClearedRecorder {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
