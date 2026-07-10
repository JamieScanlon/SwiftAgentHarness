import Foundation
import EasyJSON
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Active memory control store")
struct ActiveMemoryControlStoreTests {
    @Test("missing control file means enabled")
    func missingFileDefaultsOn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveMemoryControlStore(rootDirectory: root)
        #expect(store.isEnabled())
    }

    @Test("setEnabled persists and toggles")
    func setEnabledPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveMemoryControlStore(rootDirectory: root)
        try store.setEnabled(false)
        #expect(!store.isEnabled())
        try store.setEnabled(true)
        #expect(store.isEnabled())
        #expect(FileManager.default.fileExists(atPath: store.controlFileURL.path))
    }

    @Test("statusSummary includes config and soft lines")
    func statusSummaryShape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveMemoryControlStore(rootDirectory: root)
        let summary = store.statusSummary(config: .default, sessionEnabled: true)
        #expect(summary.contains("Config activeMemoryEnabled: on"))
        #expect(summary.contains("Active memory (global soft): on"))
        #expect(summary.contains("Active memory (session): on"))
        #expect(summary.contains("queryMode: recent"))
        #expect(summary.contains("promptStyle: balanced"))
        #expect(summary.contains("logging: on"))
    }
}

@Suite("Active memory session flags")
struct ActiveMemorySessionFlagsTests {
    @Test("absent keys use defaults")
    func absentDefaults() {
        #expect(ActiveMemorySessionFlags.isSessionEnabled(metadata: nil))
        #expect(!ActiveMemorySessionFlags.isVerbose(metadata: nil))
        #expect(!ActiveMemorySessionFlags.isTrace(metadata: nil))
    }

    @Test("writers round-trip on/off")
    func writersRoundTrip() {
        let off = ActiveMemorySessionFlags.withSessionEnabled(false, metadata: nil)
        #expect(!ActiveMemorySessionFlags.isSessionEnabled(metadata: off))
        let verbose = ActiveMemorySessionFlags.withVerbose(true, metadata: off)
        #expect(ActiveMemorySessionFlags.isVerbose(metadata: verbose))
        let trace = ActiveMemorySessionFlags.withTrace(true, metadata: verbose)
        #expect(ActiveMemorySessionFlags.isTrace(metadata: trace))
        #expect(!ActiveMemorySessionFlags.isSessionEnabled(metadata: trace))
    }
}

@Suite("Active memory soft gates and diagnostics")
struct ActiveMemoryObservabilityGateTests {
    private func makeSession(chatType: MemoryChatType = .direct) -> MemorySessionContext {
        MemorySessionContext(
            conversationID: UUID(),
            cwd: "/tmp",
            canonicalGitRoot: nil,
            memoryDirectory: URL(fileURLWithPath: "/tmp/memory"),
            chatType: chatType
        )
    }

    @Test("config off yields disabled outcome")
    func configOffDisabled() async {
        var config = MemoryConfiguration.default
        config.activeMemoryEnabled = false
        let service = ActiveMemoryPreReplyService(config: config)
        let outcome = await service.recallOutcomeIfEnabled(
            session: makeSession(),
            userQuery: "hello",
            sessionEnabled: true
        )
        #expect(outcome.note == nil)
        #expect(outcome.diagnostics.status == .disabled)
        #expect(outcome.diagnostics.skipReason == "config")
    }

    @Test("global soft off yields disabled even when session on")
    func globalOffDisabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let control = ActiveMemoryControlStore(rootDirectory: root)
        try control.setEnabled(false)
        let service = ActiveMemoryPreReplyService(config: .default, controlStore: control)
        let outcome = await service.recallOutcomeIfEnabled(
            session: makeSession(),
            userQuery: "hello",
            sessionEnabled: true
        )
        #expect(outcome.diagnostics.status == .disabled)
        #expect(outcome.diagnostics.skipReason == "global")
    }

    @Test("session soft off yields disabled")
    func sessionOffDisabled() async {
        let service = ActiveMemoryPreReplyService(config: .default)
        let outcome = await service.recallOutcomeIfEnabled(
            session: makeSession(),
            userQuery: "hello",
            sessionEnabled: false
        )
        #expect(outcome.diagnostics.status == .disabled)
        #expect(outcome.diagnostics.skipReason == "session")
    }

    @Test("ok and none diagnostics include elapsed and summary chars")
    func okAndNoneDiagnostics() async {
        final class NoteRunner: ActiveMemoryPreReplyRunning, @unchecked Sendable {
            let note: String?
            init(note: String?) { self.note = note }
            func blockingRecallSummary(
                session: MemorySessionContext,
                userQuery: String?,
                lane: RecallLane,
                timeoutMs: Int,
                maxSummaryChars: Int
            ) async -> String? {
                note
            }
        }
        let service = ActiveMemoryPreReplyService(config: .default)
        await service.setRunner(NoteRunner(note: "User prefers Grafana."))
        // Standing cold returns nil; situational returns note → ok
        let ok = await service.recallOutcomeIfEnabled(
            session: makeSession(),
            userQuery: "grafana",
            sessionEnabled: true
        )
        #expect(ok.diagnostics.status == .ok)
        #expect(ok.diagnostics.summaryChars > 0)
        #expect(ok.diagnostics.elapsedMs >= 0)
        #expect(ok.note?.contains("Grafana") == true)

        let noneService = ActiveMemoryPreReplyService(config: .default)
        await noneService.setRunner(NoteRunner(note: nil))
        let none = await noneService.recallOutcomeIfEnabled(
            session: makeSession(),
            userQuery: "nothing",
            sessionEnabled: true
        )
        #expect(none.diagnostics.status == .none)
        #expect(none.diagnostics.summaryChars == 0)
    }

    @Test("loader reads activeMemoryLogging")
    func loaderLoggingKnob() {
        #expect(MemoryConfiguration.default.activeMemoryLogging == true)
        let off = MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryLogging": false])
        #expect(off.activeMemoryLogging == false)
    }

    @Test("followUpContent respects verbose and trace flags")
    func followUpContentGating() throws {
        let diag = ActiveMemoryTurnDiagnostics(
            status: .ok,
            elapsedMs: 42,
            queryMode: .recent,
            summaryChars: 10,
            note: "hello note",
            skipReason: nil
        )
        #expect(diag.followUpContent(verbose: false, trace: false) == nil)
        let verboseOnly = try #require(diag.followUpContent(verbose: true, trace: false))
        #expect(verboseOnly.contains("status=ok"))
        #expect(verboseOnly.contains("elapsed=42ms"))
        #expect(!verboseOnly.contains("Active Memory Debug:"))
        let both = try #require(diag.followUpContent(verbose: true, trace: true))
        #expect(both.contains("Active Memory Debug: hello note"))
    }
}

@Suite("Directive verbose/trace parsing")
struct ActiveMemoryDirectiveParseTests {
    @Test("parses verbose and trace on/off")
    func parseOnOff() {
        let verboseOn = DirectiveCatalog.parseToken(from: "/verbose on")
        #expect(verboseOn?.directive.kind == .verbose)
        #expect(verboseOn?.directive.onOffFlag == true)
        let traceOff = DirectiveCatalog.parseToken(from: "/trace off")
        #expect(traceOff?.directive.kind == .trace)
        #expect(traceOff?.directive.onOffFlag == false)
        #expect(DirectiveCatalog.isDirective("trace"))
    }
}
