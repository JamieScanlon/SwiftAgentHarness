import Foundation
import SwiftAgentKit

struct ContextEngineProjectionContext: Sendable {
    let lastPromptTokens: Int?
    let lastContextLimitTokens: Int?
    let resolvedMode: ResolvedModeProfile
    let enableContextTransform: Bool
    let projectionPolicy: ContextEngineProjectionPolicyInput
}
