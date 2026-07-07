import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelSurfacePluginFactory")
struct ChannelSurfacePluginFactoryTests {
    @Test("builds surface with streaming preset and outbound adapter")
    func buildsSurface() {
        final class WireStub: ChannelOutboundListening, @unchecked Sendable {
            func send(_ message: ChannelOutboundMessage) async -> ChannelSendResult {
                .sent(messageId: "1")
            }
        }
        let surface = ChannelSurfacePluginFactory.build(
            channel: .slack,
            meta: ChannelSurfaceMeta(platformIdentity: "bot", transportKindRaw: "mock"),
            listener: WireStub(),
            heartbeat: nil,
            streamingCapabilities: .socialChannel,
            chunkLimit: 2000
        )
        #expect(surface.id == .slack)
        #expect(surface.outbound.textChunkLimit == 2000)
        #expect(surface.streamingCapabilities.granularity == StreamingSurfaceCapabilities.socialChannel.granularity)
        #expect(surface.messageToolDescriptor?.describeMessageTool().isEmpty == false)
        #expect(surface.approvalCapability != nil)
    }
}
