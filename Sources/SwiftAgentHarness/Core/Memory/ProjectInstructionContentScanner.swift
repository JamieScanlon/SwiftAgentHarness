import Foundation

enum ProjectInstructionContentScanner {
    struct ScanResult: Equatable {
        let isClean: Bool
        let matchedThreatIDs: [String]
    }

    private static let injectionPatterns: [(id: String, pattern: String)] = [
        ("injection_ignore_previous", "(?i)ignore\\s+previous\\s+instructions"),
        ("injection_you_are_now", "(?i)you\\s+are\\s+now"),
        ("injection_do_not_tell", "(?i)do\\s+not\\s+tell\\s+the\\s+user"),
        ("injection_system_override", "(?i)system\\s+prompt\\s+override"),
        ("injection_disregard_rules", "(?i)disregard\\s+your\\s+rules"),
        ("injection_act_as_if", "(?i)act\\s+as\\s+if\\s+you\\s+have\\s+no\\s+restrictions"),
    ]

    private static let exfilPatterns: [(id: String, pattern: String)] = [
        ("exfil_curl_env", "(?i)(curl|wget)[^\\n]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)"),
        ("exfil_dotenv", "(?i)cat\\s+\\.(env|netrc|pgpass|npmrc|pypirc)"),
        ("exfil_ssh_keys", "(?i)(authorized_keys|~\\/\\.ssh)"),
    ]

    static func scan(_ content: String) -> ScanResult {
        var matched: [String] = []
        for (id, pattern) in injectionPatterns + exfilPatterns {
            if content.range(of: pattern, options: .regularExpression) != nil {
                matched.append(id)
            }
        }
        if containsInvisibleUnicode(content) {
            matched.append("invisible_unicode")
        }
        return ScanResult(isClean: matched.isEmpty, matchedThreatIDs: matched.sorted())
    }

    private static func containsInvisibleUnicode(_ content: String) -> Bool {
        for scalar in content.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200D, 0x2060, 0xFEFF, 0x202A...0x202E:
                return true
            default:
                continue
            }
        }
        return false
    }
}

enum MemoryContentScanner {
    static func validateWrite(_ content: String) -> Result<Void, MemoryWriteScanError> {
        let scan = ProjectInstructionContentScanner.scan(content)
        guard scan.isClean else {
            return .failure(.threatsDetected(scan.matchedThreatIDs))
        }
        return .success(())
    }

    static func validateWriteIfMemoryTarget(
        path: String,
        memoryDirectory: URL?,
        content: String
    ) -> Result<Void, MemoryWriteScanError> {
        guard let memoryDirectory,
              AgentMemoryPathResolver.isPathInsideMemoryDirectory(path, memoryDirectory: memoryDirectory) else {
            return .success(())
        }
        return validateWrite(content)
    }
}

enum MemoryWriteScanError: Error, Equatable {
    case threatsDetected([String])
}
