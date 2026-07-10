import Foundation

struct SkillWorkshopScanResult: Sendable, Equatable {
    let critical: [SkillWorkshopScanFinding]
    let warn: [SkillWorkshopScanFinding]

    var hasCritical: Bool { !critical.isEmpty }

    var allFindings: [SkillWorkshopScanFinding] { critical + warn }
}

enum SkillWorkshopContentScanner {
    private static let criticalPatterns: [(id: String, pattern: String, message: String)] = [
        ("injection_ignore_instructions", "(?i)ignore\\s+(all\\s+)?(prior|previous|above)\\s+instructions", "Content attempts to override prior instructions"),
        ("injection_hidden_prompt", "(?i)(system\\s+prompt|developer\\s+message|hidden\\s+instructions?)", "Content references hidden or system prompt material"),
        ("injection_tool_bypass", "(?i)(bypass|skip|disable)\\s+(tool|approval|permission)", "Content encourages bypassing tool or approval flows"),
        ("pipe_to_shell", "(?i)(curl|wget)[^\\n]*\\|\\s*(ba)?sh", "Fetch-and-execute shell pattern detected"),
        ("secret_exfiltration", "(?i)(curl|wget)[^\\n]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API_KEY)", "Content may exfiltrate secrets over the network"),
    ]

    private static let warnPatterns: [(id: String, pattern: String, message: String)] = [
        ("destructive_delete", "(?i)rm\\s+-rf\\s+/", "Broad destructive delete pattern"),
        ("permissive_chmod", "(?i)chmod\\s+777", "Overly permissive chmod pattern"),
    ]

    static func scan(_ content: String) -> SkillWorkshopScanResult {
        var critical: [SkillWorkshopScanFinding] = []
        var warn: [SkillWorkshopScanFinding] = []

        for (id, pattern, message) in criticalPatterns {
            if content.range(of: pattern, options: .regularExpression) != nil {
                critical.append(SkillWorkshopScanFinding(ruleID: id, severity: "critical", message: message))
            }
        }

        let baseScan = ProjectInstructionContentScanner.scan(content)
        for threat in baseScan.matchedThreatIDs {
            if !critical.contains(where: { $0.ruleID == threat }) {
                critical.append(SkillWorkshopScanFinding(ruleID: threat, severity: "critical", message: "Matched security rule \(threat)"))
            }
        }

        for (id, pattern, message) in warnPatterns {
            if content.range(of: pattern, options: .regularExpression) != nil {
                warn.append(SkillWorkshopScanFinding(ruleID: id, severity: "warn", message: message))
            }
        }

        return SkillWorkshopScanResult(critical: critical, warn: warn)
    }
}
