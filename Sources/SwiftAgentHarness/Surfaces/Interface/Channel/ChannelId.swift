import Foundation

public enum ChannelId: String, Sendable, Codable {
    case slack
    case telegram
    case discord
    case email
}
