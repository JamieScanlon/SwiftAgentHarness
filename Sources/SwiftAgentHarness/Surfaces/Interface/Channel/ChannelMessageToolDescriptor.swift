import Foundation

public struct MockChannelMessageToolDescriptor: ChannelMessageToolDescribing {
    public let channel: ChannelId

    public init(channel: ChannelId) {
        self.channel = channel
    }

    public func describeMessageTool() -> [MessageToolActionSchema] {
        [
            MessageToolActionSchema(
                action: "post",
                mediaParams: [
                    MessageToolMediaParamDescriptor(
                        name: "coverImageURL",
                        type: "string",
                        description: "Optional cover image for \(channel.rawValue) cards."
                    ),
                ]
            ),
        ]
    }
}
