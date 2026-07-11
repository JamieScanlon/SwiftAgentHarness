import Foundation

enum SkillActivationBodyFormatter {
    static func formattedActivateResult(name: String, fullInstructions: String) -> String {
        "\(name):\n\(fullInstructions)"
    }
}
