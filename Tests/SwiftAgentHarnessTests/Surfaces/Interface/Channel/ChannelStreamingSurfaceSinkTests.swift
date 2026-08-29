import EasyJSON
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("Channel streaming surface sink")
struct ChannelStreamingSurfaceSinkTests {
    @Test("sendBlock delivers through outbound adapter")
    func sendBlock() async {
        let config = ChannelListenerConfig(enabled: true)
        let logger = Logger(label: "test")
        let listener = MockChannelListener(id: .slack, config: config, logger: logger)
        let outbound = DefaultChannelOutboundAdapter(listener: listener, chunkLimit: 100)
        let sink = ChannelStreamingSurfaceSink(
            outbound: outbound,
            threading: DefaultChannelThreadingAdapter(),
            target: ChannelDeliveryTarget(chatId: "C1", threadId: nil, replyToMessageId: nil)
        )
        await sink.sendBlock("hello")
        #expect(listener.sentMessages.count == 1)
        #expect(listener.sentMessages.first?.text == "hello")
    }
}

@Suite("Message tool schema registry")
struct MessageToolSchemaRegistryTests {
    @Test("merged schema adds media object when descriptors registered")
    func mergedSchema() {
        MessageToolSchemaRegistry.register(surfaceID: "test-surface", actionSchemas: [
            MessageToolActionSchema(
                action: "post",
                mediaParams: [
                    MessageToolMediaParamDescriptor(
                        name: "avatarURL",
                        type: "string",
                        description: "Avatar"
                    ),
                ]
            ),
        ])
        let base: JSON = .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
        let merged = MessageToolSchemaRegistry.mergedRawSchema(base: base)
        guard case .object(let root) = merged,
              case .object(let props) = root["properties"],
              case .object = props["media"] else {
            Issue.record("expected media property in merged schema")
            return
        }
    }
}
