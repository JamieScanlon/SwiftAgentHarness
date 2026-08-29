import Foundation
import Logging
import SwiftAgentKit
import Synchronization
import Testing
@testable import SwiftAgentHarness

/// The meter that finally supplies `TriggerSpendPorts.conversationCostUSD`.
///
/// Its whole job is deciding *settled* from *not settled yet*, because the two failure directions
/// are both silent: settle too early and the ledger bills a fraction of a run and never revisits it;
/// never settle and the charge pends until retention writes it off, having cost a lookup on every
/// admission in between.
@Suite("TriggerConversationCostMeter")
struct TriggerConversationCostMeterTests {
    private static let conversation = UUID()
    private static let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func run(
        outcome: ConversationRunOutcome,
        usd: Double? = nil,
        startedAt: Date? = base,
        errorClass: String? = nil
    ) -> ConversationRunInfo {
        ConversationRunInfo(
            id: UUID(),
            conversationID: Self.conversation,
            startedAt: startedAt,
            endedAt: outcome == .open ? nil : startedAt,
            outcome: outcome,
            iterationCount: 1,
            toolCallCount: 1,
            firstMessageId: "m1",
            errorDetails: errorClass.map { ConversationRunErrorDetails(class: $0, message: "stale_running_reconciled") },
            costRollup: usd.map { ConversationRunCostRollup(usd: $0) }
        )
    }

    private func meter(
        _ runs: [ConversationRunInfo],
        openRunGrace: TimeInterval = 3600,
        now: Date = base
    ) -> TriggerConversationCostMeter {
        TriggerConversationCostMeter(
            listRuns: { _ in runs },
            openRunGrace: openRunGrace,
            now: { now },
            logger: Logger(label: "test")
        )
    }

    // MARK: - Not settled

    /// Charging zero here would permanently write the run off: a settled charge is removed from
    /// `pending`, so "free" is not a guess that can be revisited.
    @Test("a conversation with no runs yet is not settled")
    func noRunsIsUnsettled() async {
        #expect(await meter([]).settledCostUSD(conversationID: Self.conversation) == nil)
    }

    /// `.open` is the only in-flight outcome, and an open run's `costRollup` already carries partial
    /// mid-run cost — settling now bills a fraction and never returns to it.
    @Test("an in-flight run holds up settlement")
    func openRunIsUnsettled() async {
        let runs = [run(outcome: .completed, usd: 2), run(outcome: .open, usd: 1)]
        #expect(await meter(runs).settledCostUSD(conversationID: Self.conversation) == nil)
    }

    /// A run with no `startedAt` has no age to judge, so the grace period can never expire for it.
    @Test("an open run with no start time never goes stale")
    func openRunWithoutStartNeverStale() async {
        let runs = [run(outcome: .completed, usd: 2), run(outcome: .open, startedAt: nil)]
        let late = Self.base.addingTimeInterval(86_400)
        #expect(await meter(runs, now: late).settledCostUSD(conversationID: Self.conversation) == nil)
    }

    /// Every open run has to be stale. One fresh run among several means the conversation is still
    /// genuinely working.
    @Test("one fresh open run keeps the conversation unsettled")
    func mixedOpenRunAgesAreUnsettled() async {
        let runs = [
            run(outcome: .open, startedAt: Self.base),
            run(outcome: .open, startedAt: Self.base.addingTimeInterval(7200)),
        ]
        let now = Self.base.addingTimeInterval(9000)
        #expect(await meter(runs, openRunGrace: 3600, now: now).settledCostUSD(conversationID: Self.conversation) == nil)
    }

    // MARK: - Settled

    @Test("a finished conversation settles at the sum of its run rollups")
    func terminalRunsSum() async {
        let runs = [run(outcome: .completed, usd: 2.5), run(outcome: .completed, usd: 0.25)]
        #expect(await meter(runs).settledCostUSD(conversationID: Self.conversation) == 2.75)
    }

    /// The coverage gap, pinned rather than hidden: only the sub-agent completion path attaches
    /// usage, so an ordinary trigger fire has no rollup at all. Treating that as "not settled" would
    /// leave every such charge pending forever, so it bills zero — which is why the wiring warns
    /// that ceilings metered this way see only delegate spend.
    @Test("a finished run with no rollup bills zero rather than pending forever")
    func terminalRunWithoutRollupBillsZero() async {
        let runs = [run(outcome: .completed, usd: nil)]
        #expect(await meter(runs).settledCostUSD(conversationID: Self.conversation) == 0)
    }

    /// Every non-`open` outcome is terminal. `.errored` in particular is how a crashed or abandoned
    /// run projects — excluding it is exactly how a charge gets stuck for the years `prunePending`
    /// allows.
    @Test("cancelled, bounded and orphaned runs all settle")
    func allTerminalOutcomesSettle() async {
        for outcome in [ConversationRunOutcome.cancelled, .bounded, .errored] {
            let runs = [run(outcome: outcome, usd: 1.5, errorClass: outcome == .errored ? "run_orphaned" : nil)]
            #expect(await meter(runs).settledCostUSD(conversationID: Self.conversation) == 1.5)
        }
    }

    /// Nothing in the harness times a run out, so a wedged lane in a live process would otherwise
    /// pin the charge until retention dropped it — years, at the default configuration.
    @Test("an open run past the grace period no longer blocks settlement")
    func staleOpenRunReleasesSettlement() async {
        let runs = [
            run(outcome: .completed, usd: 3),
            run(outcome: .open, usd: 99, startedAt: Self.base),
        ]
        let now = Self.base.addingTimeInterval(7200)
        // The abandoned run's own partial cost is still excluded — only terminal runs are billed.
        #expect(await meter(runs, openRunGrace: 3600, now: now).settledCostUSD(conversationID: Self.conversation) == 3)
    }

    @Test("the port shape matches the spend port")
    func portMatchesSpendPort() async {
        let ports = TriggerSpendPorts(
            conversationCostUSD: meter([run(outcome: .completed, usd: 1)]).port,
            notify: { _ in }
        )
        #expect(await ports.conversationCostUSD(Self.conversation) == 1)
    }

    // MARK: - Paging

    /// `ConversationRunListFilter` clamps `limit` to 200, so a conversation with more runs than that
    /// would meter only its newest page — undercounting silently, which on a spend ceiling is the
    /// failure that matters.
    @Test("paging follows the cursor to exhaustion")
    func drainsEveryPage() async {
        let pages: [String?: ConversationRunListResponse] = [
            nil: ConversationRunListResponse(runs: [run(outcome: .completed, usd: 1)], cursor: "p2"),
            "p2": ConversationRunListResponse(runs: [run(outcome: .completed, usd: 2)], cursor: "p3"),
            "p3": ConversationRunListResponse(runs: [run(outcome: .completed, usd: 4)], cursor: nil),
        ]
        let walk = await TriggerConversationCostMeter.drainPages { cursor in
            pages[cursor] ?? ConversationRunListResponse(runs: [])
        }
        #expect(walk.runs.compactMap { $0.costRollup?.usd } == [1, 2, 4])
        #expect(walk.truncated == false)
    }

    /// A server that keeps handing back the same cursor would spin forever, stalling every admission
    /// for the source. Worse than undercounting.
    @Test("a repeated cursor stops the walk")
    func repeatedCursorTerminates() async {
        let walk = await TriggerConversationCostMeter.drainPages { _ in
            ConversationRunListResponse(runs: [self.run(outcome: .completed, usd: 1)], cursor: "same")
        }
        #expect(walk.runs.count == 2)
        #expect(walk.truncated == false)
    }

    @Test("an empty page ends the walk even when a cursor is offered")
    func emptyPageTerminates() async {
        let walk = await TriggerConversationCostMeter.drainPages { _ in
            ConversationRunListResponse(runs: [], cursor: "more")
        }
        #expect(walk.runs.isEmpty)
        #expect(walk.truncated == false)
    }

    /// A server that always offers a *new* cursor defeats the repeat check, so the page count is the
    /// backstop. Each page here yields a distinct cursor, so only the bound stops the walk.
    @Test("the page walk is bounded")
    func pageWalkIsBounded() async {
        let walk = await TriggerConversationCostMeter.drainPages(maximumPages: 3) { cursor in
            ConversationRunListResponse(
                runs: [self.run(outcome: .completed, usd: 1)],
                cursor: (cursor ?? "c") + "x",
                total: 99
            )
        }
        #expect(walk.runs.count == 3)
        // Stopping early has to be *reported*, not inferred from a count nobody compares.
        #expect(walk.truncated)
        #expect(walk.total == 99)
    }

    // MARK: - Production wiring

    /// `runRollups` is the only path production takes, and none of the paging tests above touch it.
    /// Drop `cursor:` from the filter it builds and every one of them still passes, while a
    /// conversation over one page long gets billed twice — the walk would re-collect page one until
    /// the repeat-cursor guard stopped it.
    @Test("the production meter threads the cursor and asks for full pages")
    func runRollupsThreadsCursorAndLimit() async throws {
        let runtime = RecordingRunsRuntime(pages: [
            nil: ConversationRunListResponse(runs: [run(outcome: .completed, usd: 1)], cursor: "p2"),
            "p2": ConversationRunListResponse(runs: [run(outcome: .completed, usd: 2)], cursor: nil),
        ])
        let meter = TriggerConversationCostMeter.runRollups(runtime: runtime, logger: Logger(label: "test"))
        #expect(await meter.settledCostUSD(conversationID: Self.conversation) == 3)

        let calls = runtime.calls
        #expect(calls.map(\.cursor) == [nil, "p2"])
        #expect(calls.allSatisfy { $0.limit == 200 })
        #expect(calls.allSatisfy { $0.conversationID == Self.conversation })
    }
}

/// Records what the meter actually asked the runtime for.
///
/// Narrow on purpose: the value is in the three fields it captures, and everything else is the
/// protocol's unavoidable surface. `Mutex`, not `NSLock` — the recorder is reached from `async`.
final class RecordingRunsRuntime: APILayerChatRuntimeManaging, Sendable {
    struct Call: Sendable, Equatable {
        var conversationID: UUID
        var cursor: String?
        var limit: Int
    }

    private let pages: [String?: ConversationRunListResponse]
    private let recorded = Mutex<[Call]>([])

    init(pages: [String?: ConversationRunListResponse]) {
        self.pages = pages
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func apiListConversationRuns(
        conversationID: UUID,
        filter: ConversationRunListFilter
    ) async -> ConversationRunListResponse {
        recorded.withLock {
            $0.append(Call(conversationID: conversationID, cursor: filter.cursor, limit: filter.limit))
        }
        return pages[filter.cursor] ?? ConversationRunListResponse(runs: [])
    }

    // MARK: - Unused protocol surface

    func apiMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        _ = conversationID
        return AsyncStream { $0.finish() }
    }

    func apiSendMessageAndStreamResponse(
        conversationID: UUID,
        _ text: String,
        images: [Message.Image],
        enableTools: Bool,
        enableAgents: Bool,
        expectedPreviousTailHarnessMessageID: UUID?,
        inputTrustRaw: String?,
        resolvedInputTrustClass: TrustPolicyClass? = nil,
        systemReminder: String?,
        originSurface: String? = nil,
        originSenderID: String? = nil,
        originSenderIsOwner: Bool? = nil
    ) async throws -> ChatStreamResponse {
        throw APILayerConversationAPIError.unsupported
    }

    func apiRevertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        throw APILayerConversationAPIError.unsupported
    }

    func apiSplitConversationAtUserMessage(
        conversationID: UUID,
        messageID: UUID,
        enableTools: Bool,
        enableAgents: Bool
    ) async throws -> ChatStreamResponse {
        throw APILayerConversationAPIError.unsupported
    }

    func apiCancelMessageStream() async {}

    func apiSetOrchestrationStateTopicRefreshHandler(
        _ handler: @escaping @Sendable (UUID, ConversationOrchestrationState) async -> Void
    ) async {
        _ = handler
    }

    func apiClearOrchestrationStateTopicRefreshHandler() async {}

    func apiStartConversationReplay(conversationID: UUID, enableTools: Bool, enableAgents: Bool) async throws {
        throw APILayerConversationAPIError.unsupported
    }

    func apiStopConversationReplay(conversationID: UUID) async { _ = conversationID }

    func apiIsConversationReplayActive(conversationID: UUID) async -> Bool { false }

    func apiRequestTurnLoopStop(conversationID: UUID) async { _ = conversationID }

    func apiCancelRun(conversationID: UUID, runID: UUID) async throws {}

    func apiGetConversationRun(
        conversationID: UUID,
        runID: UUID,
        includeProjectionDetail: Bool
    ) async -> ConversationRunInfo? {
        nil
    }
}
