import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Exec approval store and delivery")
struct ExecApprovalTests {
    @Test("resolve wakes waiters with approved resolution")
    func resolveWakesWaiters() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "abc", command: "rm -rf /")
        async let waited = store.waitForResolution(id: "abc", timeoutSeconds: 5)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolution = await store.resolve(id: "abc", approved: true)
        #expect(resolution == .approved(durable: false))
        #expect(await waited == .approved(durable: false))
    }

    @Test("resolve returns nil for unknown id")
    func resolveUnknownID() async {
        let store = ExecApprovalStore()
        #expect(await store.resolve(id: "missing", approved: true) == nil)
    }

    @Test("durable approval pre-approves commands by command name")
    func durableApproval() async {
        let store = ExecApprovalStore()
        await store.registerPending(id: "abc", command: "git push")
        _ = await store.resolve(id: "abc", approved: true, durable: true)
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
        await store.registerPending(id: "abc", command: "git push origin main")
        _ = await store.resolve(id: "abc", approved: true, durable: true)
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
        let delivery = DefaultExecApprovalDelivery(store: store, waitTimeoutSeconds: 5)
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
        let delivery = DefaultExecApprovalDelivery(store: store, waitTimeoutSeconds: 5)
        let request = ExecApprovalRequest(
            id: "req-1",
            command: "curl example.com",
            title: "Exec approval",
            description: "curl example.com"
        )
        async let result = delivery.requestApproval(request, headless: false)
        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolved = await store.resolve(id: "req-1", approved: true)
        #expect(resolved == .approved(durable: false))
        #expect(await result == .approved)
    }

    @Test("channel delivery posts approval card to mock listener")
    func channelDeliveryPostsCard() async throws {
        let store = ExecApprovalStore()
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
        let route = ExecApprovalChannelRoute(
            listener: listener,
            chatId: "chat-1",
            threadId: "thread-1"
        )
        let delivery = ChannelExecApprovalDelivery(store: store, route: route, waitTimeoutSeconds: 0.05)
        let request = ExecApprovalRequest(
            id: "card-1",
            command: "npm test",
            title: "Exec approval",
            description: "npm test"
        )
        async let approval = delivery.requestApproval(request, headless: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = await store.resolve(id: "card-1", approved: true)
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
        let route = ExecApprovalChannelRoute(listener: listener, chatId: "c1", threadId: nil)
        let delivery = ChannelExecApprovalDelivery(store: ExecApprovalStore(), route: route)
        await delivery.sendFollowup(approvalID: "x", approved: true)
        #expect(listener.sentMessages.count == 1)
        #expect(listener.sentMessages[0].text.contains("approved"))
    }
}
