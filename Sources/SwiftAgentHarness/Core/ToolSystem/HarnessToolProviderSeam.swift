import Foundation
import Logging
import SwiftAgentKit

/// Per-turn context handed to host-supplied ``ToolProvider`` factories so injected providers can be conversation-scoped.
public struct HarnessToolProviderContext: Sendable {
    public let conversation: ModelConversation?
    public let workspaceRoot: String?
    public let logger: Logger?
    /// When set, tools from this provider are tagged with `group:<pluginGroupID>` for policy matching.
    public let pluginGroupID: String?

    public init(
        conversation: ModelConversation?,
        workspaceRoot: String?,
        logger: Logger?,
        pluginGroupID: String? = nil
    ) {
        self.conversation = conversation
        self.workspaceRoot = workspaceRoot
        self.logger = logger
        self.pluginGroupID = pluginGroupID
    }
}

/// Host-owned seam for contributing ``ToolProvider`` instances the harness does not define itself.
public typealias HarnessToolProviderFactory = @Sendable (HarnessToolProviderContext) -> [any ToolProvider]
