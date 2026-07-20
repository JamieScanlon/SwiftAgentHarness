import Foundation

enum SystemPromptSubagentComposition {
    static let spawnSectionSuppressions: Set<SystemPromptSectionName> = [
        .personality,
        .memory,
        .identity,
    ]

    static func spawnTaskDirective(
        taskDescription: String?,
        prompt: String?,
        userSystemPrompt: String?
    ) -> String? {
        let candidates = [taskDescription, prompt, userSystemPrompt]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
