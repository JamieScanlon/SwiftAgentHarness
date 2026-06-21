import Foundation
import Logging
import SwiftAgentKit

/// Per-turn context handed to host-supplied ``ToolProvider`` factories so injected providers can be conversation-scoped.
struct HarnessToolProviderContext: Sendable {
    let conversation: ModelConversation?
    let workspaceRoot: String?
    let logger: Logger?
}

/// Host-owned seam for contributing ``ToolProvider`` instances the harness does not define itself.
typealias HarnessToolProviderFactory = @Sendable (HarnessToolProviderContext) -> [any ToolProvider]
