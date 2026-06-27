import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("DirectiveCatalog")
struct DirectiveTests {
    @Test("Parses think level directive")
    func thinkLevel() {
        let parsed = DirectiveCatalog.parseToken(from: "/think high")
        #expect(parsed?.directive.kind == .think)
        #expect(parsed?.directive.thinkingConfig == .level(.high, budgetTokens: nil))
    }

    @Test("Parses model slug directive")
    func modelSlug() {
        let parsed = DirectiveCatalog.parseToken(from: "/model gpt-4o")
        #expect(parsed?.directive.kind == .model)
        #expect(parsed?.directive.modelSlug == "gpt-4o")
    }
}

@Suite("InlineShortcutCatalog")
struct InlineShortcutTests {
    @Test("Renders help from registry index")
    func helpRendering() {
        let registry = CoreCommandCatalog.registry(compactEnabled: true)
        let output = InlineShortcutCatalog.render(
            InlineShortcutInvocation(kind: .help),
            registry: registry
        )
        #expect(output.contains("Available commands:"))
        #expect(output.contains("/compact"))
    }

    @Test("Renders command index")
    func commandsRendering() {
        let registry = CoreCommandCatalog.registry(compactEnabled: true)
        let output = InlineShortcutCatalog.render(
            InlineShortcutInvocation(kind: .commands),
            registry: registry
        )
        #expect(output.contains("/help"))
        #expect(output.contains("/think"))
    }
}

@Suite("ControlSurfaceCapabilities")
struct ControlSurfaceCapabilitiesTests {
    @Test("Text floor is always enabled")
    func textFloor() {
        #expect(ControlSurfaceCapabilities.thinChannel.effectiveTextCommandsEnabled)
        #expect(ControlSurfaceCapabilities.socialChannel.effectiveTextCommandsEnabled)
    }
}

@Suite("ControlInputAuthorization")
struct ControlInputAuthorizationTests {
    @Test("Owner-only command falls through for non-owner")
    func ownerOnlyCommand() {
        let command = SlashCommand(
            base: SlashCommandBase(name: "model", description: "model", ownerOnly: true),
            kind: .directive
        )
        let auth = ControlInputAuthorization(isOwner: false, trustClass: .trusted, allowlistAllows: true)
        #expect(auth.authorize(command: command) == .fallThroughToPlainText)
    }
}
