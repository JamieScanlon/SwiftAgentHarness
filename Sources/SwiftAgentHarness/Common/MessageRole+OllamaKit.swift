import Foundation
import OllamaKit
import SwiftAgentKit

extension MessageRole {
    func toOllamaKitRole() -> OKChatRequestData.Message.Role {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .system:
            return .system
        case .tool:
            return .tool
        }
    }
}
