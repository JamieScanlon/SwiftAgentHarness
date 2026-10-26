import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use secrets: URLs and helper-model inputs")
struct ComputerUseSecretsTests {
    @Test("URLs that carry credentials are flagged; ordinary ones are not")
    func urls() {
        #expect(ComputerUseSecrets.secretInURL("https://user:hunter2@example.com/") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://example.com/cb?access_token=abc123") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://example.com/cb#id_token=abc&state=x") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://maps.example.com/js?API_KEY=xyz") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://s3.example.com/o?X-Amz-Signature=f00d") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://example.com/r?next=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://example.com/r?q=sk-proj-abcdefghijklmnopqrstuvwx") != nil)
        #expect(ComputerUseSecrets.secretInURL("https://docs.example.com/search?q=swift+tokens&page=2") == nil)
        #expect(ComputerUseSecrets.secretInURL("https://example.com/promo?code=SPRING") == nil)
        #expect(ComputerUseSecrets.secretInURL("https://example.com/") == nil)
    }

    @Test("Redaction removes credential values and keeps the rest readable")
    func redaction() {
        let text = """
        Log in with password: hunter2 and then open https://bob:pw@intranet.example.com/x?token=abc&page=1.
        The key is sk-proj-abcdefghijklmnopqrstuvwx and the JWT eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U.
        """
        let redacted = ComputerUseSecrets.redacting(text)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("bob:pw"))
        #expect(!redacted.contains("token=abc"))
        #expect(!redacted.contains("sk-proj-"))
        #expect(!redacted.contains("eyJhbGci"))
        #expect(redacted.contains("Log in with password: [redacted]"))
        #expect(redacted.contains("page=1"))
        #expect(redacted.contains("intranet.example.com"))
        #expect(ComputerUseSecrets.redacting("Make the title bold in TextEdit.") == "Make the title bold in TextEdit.")
    }

    @Test("open-url to a URL that embeds a secret is refused even on a granted domain")
    func classifierRefuses() {
        let classifier = ComputerUseActionClassifier()
        let context = ComputerUseClassificationContext(
            grants: ComputerUseGrantSet([.domain("example.com", tier: .click)]),
            observation: { _ in nil },
            focusedApp: nil
        )
        let blocked = classifier.classify(.openURL("https://example.com/cb?access_token=abc123"), context: context)
        guard case .outOfGrant(let reason) = blocked.actionClass else {
            Issue.record("expected outOfGrant, got \(blocked.actionClass)")
            return
        }
        #expect(reason.contains("secret"))
        #expect(classifier.classify(.openURL("https://example.com/docs"), context: context).actionClass == .navigate)
    }

    @Test("The intent checker sees the user's request with secrets redacted")
    func intentCheckerRedacts() async throws {
        let dispatcher = ComputerUseSessionFixtures.intentDispatcher(verdict: .act)
        let checker = ComputerUseSessionFixtures.checker(dispatcher)
        _ = await checker.evaluate(ComputerUseIntentCheckInput(
            conversationID: nil, runID: nil, accountID: nil,
            userRequest: ["Sign in with password: hunter2 and export the report."],
            history: [],
            proposed: ComputerUseProposedAction(kind: "click", app: "com.apple.TextEdit", domain: nil, elementRole: "AXButton")
        ))
        let request = try #require(await dispatcher.requests.first)
        let state = try #require(String(data: try JSONEncoder().encode(request.state), encoding: .utf8))
        #expect(!state.contains("hunter2"))
        #expect(state.contains("export the report"))
    }

    @Test("Screen results are wrapped as screen content, so the injection probe sees them, with secrets redacted")
    func probeEligibility() {
        let decision = ToolExternalContentPolicy.resolve(toolName: ComputerUseToolProvider.observeToolName, entry: nil)
        #expect(decision.shouldWrap)
        #expect(decision.source == .screen)
        #expect(!ComputerUseSecrets.probeInput("[e3] textfield value=\"password: hunter2\"", source: .screen).contains("hunter2"))
        #expect(ComputerUseSecrets.probeInput("password: hunter2", source: .webFetch) == "password: hunter2")
    }
}
