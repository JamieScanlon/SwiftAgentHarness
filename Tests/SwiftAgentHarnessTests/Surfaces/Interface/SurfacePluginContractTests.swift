import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

/// The point of extracting ``SurfacePlugin`` is that two very different surfaces answer
/// the same questions. These tests hold both through the contract rather than through
/// their concrete types — if the contract only ever worked for one of them, it would not
/// be a contract.
@Suite("SurfacePlugin contract")
struct SurfacePluginContractTests {
    private func makeChannelPlugin(
        capabilities: ChannelCapabilities = .mock,
        streaming: StreamingSurfaceCapabilities = .socialChannel
    ) -> ChannelSurfacePlugin {
        let config = ChannelListenerConfig(platformIdentity: "mock")
        let listener = MockChannelListener(id: .slack, config: config, logger: Logger(label: "test"))
        return ChannelSurfacePluginFactory.build(
            channel: .slack,
            meta: ChannelSurfaceMeta(platformIdentity: "mock", transportKindRaw: "socket"),
            listener: listener,
            heartbeat: nil,
            streamingCapabilities: streaming,
            capabilities: capabilities
        )
    }

    @Test("Both surfaces satisfy the contract and render through one call")
    func heterogeneousSurfaces() {
        let surfaces: [any SurfacePlugin] = [makeChannelPlugin(), TUISurfacePlugin()]
        let presentation = MessagePresentation(
            title: "Deploy",
            tone: .warning,
            blocks: [.text("Ship it?"), .buttons([ApprovalButton(id: "yes", label: "Yes")])]
        )

        for surface in surfaces {
            let payload = surface.render(presentation)
            // The text floor is unconditional on every surface.
            #expect(payload.text == presentation.textFallback())
            #expect(!surface.surfaceID.isEmpty)
        }
    }

    @Test("Terminal surface declares terminal identity and capabilities")
    func terminalPlugin() {
        let plugin = TUISurfacePlugin()
        #expect(plugin.surfaceID == InteractiveSurfaceID.tui)
        #expect(plugin.surfaceCapabilities.tokenStreaming)
        #expect(plugin.surfaceCapabilities.richPresentation)
        #expect(plugin.surfaceCapabilities.nativeApprovalCards)
        // Honest absences rather than stubs.
        #expect(!plugin.surfaceCapabilities.threading)
        #expect(!plugin.surfaceCapabilities.typingIndicators)
        #expect(plugin.streamingCapabilities.granularity == .tokenDelta)
    }

    @Test("Channel surface maps its record onto the shared capabilities")
    func channelCapabilityMapping() {
        let plugin = makeChannelPlugin(
            capabilities: ChannelCapabilities(
                threading: true,
                blockStreaming: true,
                previewStreaming: true,
                nativeApprovalCards: true,
                typingIndicators: true,
                mediaAttachments: true
            )
        )
        let shared = plugin.surfaceCapabilities
        #expect(shared.threading)
        #expect(shared.blockStreaming)
        #expect(shared.previewStreaming)
        #expect(shared.nativeApprovalCards)
        #expect(shared.typingIndicators)
        #expect(shared.mediaAttachments)
        // Block-rung channel is not token streaming.
        #expect(!shared.tokenStreaming)
        #expect(plugin.surfaceID == ChannelId.slack.rawValue)
        #expect(plugin.surfaceMeta.displayName == "mock")
        #expect(plugin.surfaceMeta.kindRaw == "socket")
    }

    @Test("Channel surface reports token streaming at the token rung")
    func channelTokenRung() {
        let plugin = makeChannelPlugin(streaming: .terminal)
        #expect(plugin.surfaceCapabilities.tokenStreaming)
    }

    @Test("Presentation renderer is reachable through the contract")
    func rendererThroughContract() {
        let plugin: any SurfacePlugin = TUISurfacePlugin()
        #expect(plugin.presentationRenderer.presentationCapabilities.supported)
        #expect(plugin.presentationRenderer.textChunkLimit > 0)
    }
}

@Suite("SurfacePresentationFilter")
struct SurfacePresentationFilterTests {
    private let presentation = MessagePresentation(
        title: "Title",
        tone: .info,
        blocks: [
            .text("body"),
            .context("footnote"),
            .divider,
            .buttons([ApprovalButton(id: "ok", label: "OK")]),
            .select(options: [MessageSelectOption(id: "a", label: "A")], label: "Pick"),
        ]
    )

    @Test("Text floor survives even with no native support")
    func textFloorAlways() {
        let payload = SurfacePresentationFilter.render(presentation, capabilities: .textOnly)
        #expect(payload.richPresentation == nil)
        #expect(payload.text == presentation.textFallback())
        #expect(payload.text.contains("OK"))
    }

    @Test("Unsupported block kinds are dropped from the native payload, not the text")
    func unsupportedBlocksDegrade() throws {
        let capabilities = SurfacePresentationCapabilities(
            supported: true,
            buttons: false,
            selects: false,
            context: true,
            divider: false
        )
        let payload = SurfacePresentationFilter.render(presentation, capabilities: capabilities)
        let rich = try #require(payload.richPresentation)
        #expect(rich.blocks == [.text("body"), .context("footnote")])
        #expect(payload.text.contains("OK"))
    }

    @Test("Terminal capabilities keep everything except select")
    func terminalKeepsAllButSelect() throws {
        let payload = SurfacePresentationFilter.render(
            presentation,
            capabilities: MessagePresentationTerminalRenderer.capabilities
        )
        let rich = try #require(payload.richPresentation)
        #expect(rich.blocks.count == 4)
        #expect(!rich.blocks.contains { if case .select = $0 { return true } else { return false } })
    }

    @Test("A title-only presentation still produces a native payload")
    func titleOnlyIsRich() throws {
        let titleOnly = MessagePresentation(title: "Heads up", blocks: [])
        let payload = SurfacePresentationFilter.render(titleOnly, capabilities: .mockRich)
        let rich = try #require(payload.richPresentation)
        #expect(rich.title == "Heads up")
    }

    @Test("Channel renderer and shared filter agree")
    func channelDelegatesToSharedFilter() {
        // The channel path is now a thin alias; if the two ever diverge the degradation
        // rule has been forked.
        let viaChannel = ChannelPresentationRenderer.render(presentation, capabilities: .mockRich)
        let viaShared = SurfacePresentationFilter.render(presentation, capabilities: .mockRich)
        #expect(viaChannel == viaShared)
    }
}
