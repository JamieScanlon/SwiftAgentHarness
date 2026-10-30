import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Remote delegate idle timeout")
struct RemoteDelegateIdleTimeoutTests {
    /// The session is returned so it outlives the test body; the spawn service holds parts of it weakly.
    private func makeService() async throws -> (session: HarnessRuntimeSession, service: SubAgentSpawnService) {
        let container = try HarnessTestModelContainer.makeInMemory()
        let session = HarnessRuntimeSession(
            container: container,
            rankedRegistryEntriesProvider: { _ in [] },
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        return (session, await session.subAgentSpawnService)
    }

    private struct Invocation {
        let parentConversationID = UUID()
        let correlation = SubAgentTransportInvocationCorrelation(
            lifecycleID: "remote-\(UUID().uuidString)",
            transportKind: .acpStdio,
            sessionHandleID: "delegate_remote",
            completionHandleID: nil
        )

        func event(_ phase: SubAgentDelegateEventPhase) -> SubAgentDelegateEvent {
            SubAgentDelegateEvent(
                lifecycleID: correlation.lifecycleID,
                parentConversationID: parentConversationID,
                delegateToolName: "delegate_remote",
                phase: phase,
                completionSource: phase == .done ? "finished" : nil
            )
        }
    }

    private func follow(
        _ service: SubAgentSpawnService,
        _ invocation: Invocation,
        stream: AsyncStream<SubAgentDelegateEvent>,
        idleTimeoutSeconds: TimeInterval?,
        applyingTerminal: Bool = true
    ) async -> SubAgentSpawnService.RemoteDelegateEnding {
        await service.followRemoteDelegate(
            stream,
            correlation: invocation.correlation,
            parentConversationID: invocation.parentConversationID,
            idleTimeoutSeconds: idleTimeoutSeconds,
            applyingTerminal: applyingTerminal
        )
    }

    private func phase(_ service: SubAgentSpawnService, _ invocation: Invocation) async -> SubAgentLifecyclePhase? {
        await service.subAgentLifecycleEntry(
            parentConversationID: invocation.parentConversationID,
            lifecycleID: invocation.correlation.lifecycleID
        )?.phase
    }

    @Test("A remote delegate that goes silent is cancelled with idle-timeout and ends failed")
    func silentDelegateCancelled() async throws {
        let (session, service) = try await makeService()
        defer { withExtendedLifetime(session) {} }
        let invocation = Invocation()
        let (stream, continuation) = AsyncStream.makeStream(of: SubAgentDelegateEvent.self)
        continuation.yield(invocation.event(.running))
        let started = Date()
        let ending = await follow(service, invocation, stream: stream, idleTimeoutSeconds: 0.2)
        #expect(ending.idleTimedOut == 0.2)
        #expect(ending.terminal?.phase == .failed)
        #expect(ending.terminal?.error?.hasPrefix("idle-timeout") == true)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await phase(service, invocation) == .failed)
        continuation.finish()
    }

    @Test("A remote delegate that keeps producing events outlives its idle timeout")
    func activeDelegateContinues() async throws {
        let (session, service) = try await makeService()
        defer { withExtendedLifetime(session) {} }
        let invocation = Invocation()
        let (stream, continuation) = AsyncStream.makeStream(of: SubAgentDelegateEvent.self)
        let producer = Task {
            for _ in 0..<8 {
                continuation.yield(invocation.event(.running))
                try? await Task.sleep(for: .milliseconds(80))
            }
            continuation.yield(invocation.event(.done))
            continuation.finish()
        }
        let ending = await follow(service, invocation, stream: stream, idleTimeoutSeconds: 0.2)
        await producer.value
        #expect(ending.idleTimedOut == nil)
        #expect(ending.terminal?.phase == .done)
        #expect(await phase(service, invocation) == .done)
    }

    @Test("Awaiting approval isn't idle: the clock pauses until the delegate resumes")
    func awaitingApprovalPauses() async throws {
        let (session, service) = try await makeService()
        defer { withExtendedLifetime(session) {} }
        let invocation = Invocation()
        let (stream, continuation) = AsyncStream.makeStream(of: SubAgentDelegateEvent.self)
        let producer = Task {
            continuation.yield(invocation.event(.awaitingApproval))
            try? await Task.sleep(for: .milliseconds(600))
            continuation.yield(invocation.event(.running))
            continuation.yield(invocation.event(.done))
            continuation.finish()
        }
        let ending = await follow(service, invocation, stream: stream, idleTimeoutSeconds: 0.2)
        await producer.value
        #expect(ending.idleTimedOut == nil)
        #expect(ending.terminal?.phase == .done)
    }

    @Test("Events applied outside the stream, such as permission requests, count as activity")
    func outOfBandEventsCount() async throws {
        let (session, service) = try await makeService()
        defer { withExtendedLifetime(session) {} }
        let invocation = Invocation()
        let (stream, continuation) = AsyncStream.makeStream(of: SubAgentDelegateEvent.self)
        continuation.yield(invocation.event(.running))
        let producer = Task {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(80))
                await service.applySubAgentDelegateEvent(invocation.event(.running))
            }
            continuation.yield(invocation.event(.done))
            continuation.finish()
        }
        let ending = await follow(service, invocation, stream: stream, idleTimeoutSeconds: 0.2)
        await producer.value
        #expect(ending.idleTimedOut == nil)
        #expect(ending.terminal?.phase == .done)
    }

    @Test("With no idle timeout a quiet delegate is left to finish")
    func noIdleTimeout() async throws {
        let (session, service) = try await makeService()
        defer { withExtendedLifetime(session) {} }
        let invocation = Invocation()
        let (stream, continuation) = AsyncStream.makeStream(of: SubAgentDelegateEvent.self)
        let producer = Task {
            continuation.yield(invocation.event(.running))
            try? await Task.sleep(for: .milliseconds(400))
            continuation.yield(invocation.event(.done))
            continuation.finish()
        }
        let ending = await follow(service, invocation, stream: stream, idleTimeoutSeconds: nil)
        await producer.value
        #expect(ending.idleTimedOut == nil)
        #expect(ending.terminal?.phase == .done)
    }

    @Test("A caller that applies the terminal event itself gets it back unapplied")
    func terminalLeftToCaller() async throws {
        let (session, service) = try await makeService()
        defer { withExtendedLifetime(session) {} }
        let invocation = Invocation()
        let (stream, continuation) = AsyncStream.makeStream(of: SubAgentDelegateEvent.self)
        continuation.yield(invocation.event(.running))
        continuation.yield(invocation.event(.done))
        continuation.finish()
        let ending = await follow(service, invocation, stream: stream, idleTimeoutSeconds: 0.2, applyingTerminal: false)
        #expect(ending.terminal?.phase == .done)
        #expect(await phase(service, invocation) == .running)
    }

    @Test("The model-facing report says the delegate went silent and names its timeout")
    func report() {
        let text = SubAgentSpawnService.remoteIdleTimeoutReport(delegateName: "delegate_remote", seconds: 120)
        #expect(text.contains("delegate_remote"))
        #expect(text.contains("120s"))
        #expect(text.contains("idleTimeoutSeconds"))
    }

    @Test("A transport cancelled with a reason ends with that reason as its error")
    func cancellationReason() async {
        let store = SubAgentRemoteTransportSessionStore(sessionEvictionGraceNanoseconds: 1_000_000)
        let invocation = Invocation()
        let session = RemoteTransportSession(
            correlation: invocation.correlation,
            parentConversationID: invocation.parentConversationID,
            delegateToolName: "delegate_remote",
            status: .running
        )
        _ = await store.register(session: session, initialEvent: invocation.event(.running))
        let result = await store.cancel(
            SubAgentTransportCancellationRequest(
                lifecycleID: invocation.correlation.lifecycleID,
                transportKind: .acpStdio,
                sessionHandleID: "delegate_remote",
                reason: "idle-timeout"
            )
        )
        #expect(result.disposition == .cancelled)
        #expect(result.delegateEvents.first?.error == "idle-timeout")
    }
}

@Suite("Remote delegate limits configuration")
struct SubAgentLimitsConfigurationTests {
    @Test("Delegates default to a 300 s idle timeout when nothing is configured")
    func defaults() {
        #expect(SubAgentHostingPolicyConfiguration.empty.limits(forDelegateToolName: "delegate_any").idleTimeoutSeconds == 300)
        let parsed = SubAgentHostingPolicyConfiguration.fromPromptConfigRoot([:])
        #expect(parsed.limits(forDelegateToolName: "delegate_any").idleTimeoutSeconds == 300)
    }

    @Test("limits.idleTimeoutSeconds is read from defaults and entries: 0 turns it off, values are clamped, bad values inherit")
    func parsing() {
        let configuration = SubAgentHostingPolicyConfiguration.fromPromptConfigRoot([
            "subAgentHostingPolicy": [
                "defaults": ["limits": ["idleTimeoutSeconds": 120]],
                "entries": [
                    "delegate_off": ["limits": ["idleTimeoutSeconds": 0]],
                    "delegate_short": ["limits": ["idleTimeoutSeconds": 2]],
                    "delegate_long": ["limits": ["idleTimeoutSeconds": 99_999]],
                    "delegate_bad": ["limits": ["idleTimeoutSeconds": -5]],
                    "delegate_plain": ["routingDomain": "docs"],
                ] as [String: Any],
            ] as [String: Any],
        ])
        #expect(configuration.limits(forDelegateToolName: "delegate_off").idleTimeoutSeconds == nil)
        #expect(configuration.limits(forDelegateToolName: "delegate_short").idleTimeoutSeconds == 10)
        #expect(configuration.limits(forDelegateToolName: "delegate_long").idleTimeoutSeconds == 3600)
        #expect(configuration.limits(forDelegateToolName: "delegate_bad").idleTimeoutSeconds == 120)
        #expect(configuration.limits(forDelegateToolName: "delegate_plain").idleTimeoutSeconds == 120)
        #expect(configuration.limits(forDelegateToolName: "delegate_unlisted").idleTimeoutSeconds == 120)
        #expect(configuration.policy(forDelegateToolName: "delegate_plain").routingDomain == "docs")
    }

    @Test("Registry rows carry the delegate's limits")
    func registryCarriesLimits() async {
        let configuration = SubAgentHostingPolicyConfiguration(
            defaultPolicy: SubAgentHostingPolicy(),
            policiesByDelegateToolName: [:],
            policiesByHostPersonaID: [:],
            limitsByDelegateToolName: ["delegate_research": SubAgentLimits(idleTimeoutSeconds: 45)]
        )
        let pool = DefaultSubAgentPool(hostingPolicyConfiguration: configuration)
        let entries = [
            ToolRegistryEntry(
                definition: ToolDefinition(name: "delegate_research", description: "research", parameters: [], type: .a2aAgent),
                source: .a2a,
                transportKind: .a2a,
                effectClass: .readOnly,
                parallelHint: .parallelizable
            ),
        ]
        let registry = await pool.listSubAgents(from: entries, routingContext: nil, conversationID: nil)
        #expect(registry.first?.limits.idleTimeoutSeconds == 45)
    }
}
