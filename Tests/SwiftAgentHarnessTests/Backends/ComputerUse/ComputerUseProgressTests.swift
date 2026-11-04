import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use progress: the screen state digest")
struct ComputerUseStateDigestTests {
    private typealias F = ComputerUseFixtures

    private func observation(
        app: AppIdentity? = F.textEdit,
        windowID: String? = "w1",
        url: String? = nil,
        elements: [(Int, ElementRef)]? = nil,
        image: Bool = true
    ) -> DisplayObservation {
        var observation = F.observation(id: "o_1", app: app ?? F.textEdit, url: url, withImage: image)
        observation.target.app = app
        observation.target.windowID = windowID
        if let elements {
            let text = elements.map { depth, element in
                String(repeating: "  ", count: depth) + "[\(element.id)] \(element.role) \"\(element.label ?? "")\""
            }.joined(separator: "\n")
            observation.tree = ObservationTree(
                text: text,
                elements: Dictionary(uniqueKeysWithValues: elements.map { ($0.1.id, $0.1) }),
                capturedAt: F.epoch
            )
        } else {
            observation.tree = nil
        }
        return observation
    }

    private let form: [(Int, ElementRef)] = [
        (0, ElementRef(id: "e1", role: "AXWindow")),
        (1, ElementRef(id: "e2", role: "AXTextField", label: "Name", isFocused: true)),
        (1, ElementRef(id: "e3", role: "AXButton", label: "Save")),
    ]

    @Test("Labels, values, and ids don't change the digest; it is structural")
    func ignoresText() {
        let relabeled: [(Int, ElementRef)] = [
            (0, ElementRef(id: "e9", role: "AXWindow", label: "Untitled 2")),
            (1, ElementRef(id: "e7", role: "AXTextField", label: "Full name", isFocused: true)),
            (1, ElementRef(id: "e8", role: "AXButton", label: "Submit now")),
        ]
        #expect(ComputerUseStateDigest.of(observation(elements: form)) == ComputerUseStateDigest.of(observation(elements: relabeled)))
    }

    @Test("A different tree shape, focused role, app, or window is a different state")
    func structuralChanges() {
        let base = ComputerUseStateDigest.of(observation(elements: form))
        #expect(base != nil)
        #expect(ComputerUseStateDigest.of(observation(elements: form + [(1, ElementRef(id: "e4", role: "AXSheet"))])) != base)
        var moved = form
        moved[1].1.isFocused = false
        moved[2].1.isFocused = true
        #expect(ComputerUseStateDigest.of(observation(elements: moved)) != base)
        var deeper = form
        deeper[2].0 = 2
        #expect(ComputerUseStateDigest.of(observation(elements: deeper)) != base)
        #expect(ComputerUseStateDigest.of(observation(app: F.safari, elements: form)) != base)
        #expect(ComputerUseStateDigest.of(observation(windowID: "w2", elements: form)) != base)
    }

    @Test("The shape is each line's indentation and role, read from the compact tree the model sees")
    func shapeFromText() {
        #expect(ComputerUseStateDigest.shape("window \"Doc\" app=TextEdit\n  [e1] toolbar\n    [e2] button \"Bold\"") == ["0:window", "2:toolbar", "4:button"])
        #expect(observation(elements: form).fingerprint == ComputerUseStateDigest.of(observation(elements: form)))
    }

    @Test("A URL's page counts, its fragment doesn't")
    func urlIdentity() {
        let page = ComputerUseStateDigest.of(observation(url: "https://example.com/a?q=1", elements: form))
        #expect(ComputerUseStateDigest.of(observation(url: "https://example.com/a?q=1#top", elements: form)) == page)
        #expect(ComputerUseStateDigest.of(observation(url: "https://example.com/b?q=1", elements: form)) != page)
        #expect(ComputerUseStateDigest.of(observation(url: "https://example.com/a?q=2", elements: form)) != page)
    }

    @Test("Pixel-only observations are told apart by app, window, and URL alone")
    func pixelOnly() {
        let shot = ComputerUseStateDigest.of(observation(url: "https://example.com/a"))
        #expect(shot != nil)
        #expect(ComputerUseStateDigest.of(observation(url: "https://example.com/a")) == shot)
        #expect(ComputerUseStateDigest.of(observation(windowID: "w2", url: "https://example.com/a")) != shot)
    }

    @Test("An observation with nothing to identify it has no digest")
    func nothingToIdentify() {
        #expect(ComputerUseStateDigest.of(observation(app: nil, windowID: nil)) == nil)
    }
}

@Suite("Computer use progress: what the session counts")
struct ComputerUseSessionProgressTests {
    private static func click(_ observation: ObservationID) -> ComputerAction {
        .click(at: .ref("e2", observation: observation))
    }

    private static func make(criteria: [String] = []) async throws -> (FakeDisplayTarget, ComputerUseSession) {
        try await ComputerUseSessionFixtures.make(manifest: FakeDisplayTarget.vmManifest, successCriteria: criteria)
    }

    @Test("An acting step followed by a state not seen before made progress")
    func newState() async throws {
        let (target, session) = try await Self.make()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([Self.click("o_1")])
        await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://example.com/next")
        _ = await session.perform([ComputerUseSessionFixtures.observe])

        let log = await session.auditLog
        #expect(log.map(\.madeProgress) == [false, true, false])
        let progress = await session.progress
        #expect(progress.statesReached == 1)
        #expect(progress.lastProgressStep == 2)
    }

    @Test("Returning to a state already seen is not progress, which catches oscillation")
    func oscillation() async throws {
        let (target, session) = try await Self.make()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        for (index, url) in ["https://example.com/b", nil, "https://example.com/b"].enumerated() {
            _ = await session.perform([Self.click("o_\(index + 1)")])
            await target.setObserved(app: ComputerUseFixtures.textEdit, url: url)
            _ = await session.perform([ComputerUseSessionFixtures.observe])
        }
        #expect(await session.progress.statesReached == 1)
        #expect(await session.auditLog.filter(\.madeProgress).map(\.step) == [2])
    }

    @Test("A state that appears after only observing or waiting is not progress")
    func noActingStep() async throws {
        let (target, session) = try await Self.make()
        _ = await session.perform([ComputerUseSessionFixtures.observe, .wait(milliseconds: 1)])
        await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://example.com/loaded")
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(await session.progress.statesReached == 0)
        #expect(await session.progress.lastProgressStep == nil)
    }

    @Test("A known failure never earns progress, but an unverifiable action can")
    func failedActions() async throws {
        for (effect, credited) in [(ActionEffect.suspectedNoop, false), (.refused, false), (.unverifiable, true), (.partial, true)] {
            let (target, session) = try await Self.make()
            await target.setOutcomes { _, index in ActionOutcome(action: index, effect: effect) }
            _ = await session.perform([ComputerUseSessionFixtures.observe])
            _ = await session.perform([Self.click("o_1")])
            await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://example.com/after")
            _ = await session.perform([ComputerUseSessionFixtures.observe])
            #expect(await session.progress.statesReached == (credited ? 1 : 0), "\(effect)")
        }
    }

    @Test("A state the user reached during takeover isn't credited to the agent's last action")
    func takeoverClears() async throws {
        let (target, session) = try await Self.make()
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        _ = await session.perform([Self.click("o_1")])
        try await session.setTakeover(true)
        await target.setObserved(app: ComputerUseFixtures.textEdit, url: "https://example.com/user-went-here")
        try await session.setTakeover(false)
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        #expect(await session.progress.statesReached == 0)
    }

    @Test("A criterion cited as the harness lists it, number then text, counts")
    func criterionCitedAsListed() async throws {
        let (_, session) = try await Self.make(criteria: ["The text is bold", "The file is saved"])
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        try await session.verify(criterion: "1. The text is bold", met: true, evidence: "bold", observation: "o_1")
        await #expect(throws: ComputerUseSessionError.unknownCriterion("1. The file is saved")) {
            try await session.verify(criterion: "1. The file is saved", met: true, evidence: "number and text disagree", observation: "o_1")
        }
        #expect(await session.unverifiedCriteria.map(\.number) == [2])
        #expect(await session.verifications.count == 1)
        #expect(await session.progress.criteriaVerified == 1)
    }

    @Test("A criterion newly verified as met is progress; repeating it or recording not-met isn't")
    func verifiedCriteria() async throws {
        let (_, session) = try await Self.make(criteria: ["The text is bold", "The file is saved"])
        _ = await session.perform([ComputerUseSessionFixtures.observe])
        try await session.verify(criterion: "The text is bold", met: false, evidence: "plain", observation: "o_1")
        #expect(await session.progress.criteriaVerified == 0)
        try await session.verify(criterion: "1", met: true, evidence: "bold", observation: "o_1")
        try await session.verify(criterion: "The text is bold", met: true, evidence: "still bold", observation: "o_1")
        await #expect(throws: ComputerUseSessionError.unknownCriterion("Something else entirely")) {
            try await session.verify(criterion: "Something else entirely", met: true, evidence: "?", observation: "o_1")
        }
        let progress = await session.progress
        #expect(progress.criteriaVerified == 1)
        #expect(progress.lastProgressStep == 1)
    }
}
