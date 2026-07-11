import Foundation

struct SystemPromptAssemblyRenderAudit: Sendable, Equatable {
    let text: String
    let product: SystemPromptAssemblyRenderProduct
    let effectiveUserSystemPrompt: String
    let providerStablePrefix: String?
    let activatedSkillBodies: [String: String]
}
