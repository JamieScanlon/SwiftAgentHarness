import Foundation
import Logging

actor ToolPolicyCoherenceDiagnostics {
    static let shared = ToolPolicyCoherenceDiagnostics()

    private var emittedKeys: Set<String> = []
    private var catalogFingerprint: String = ""

    func log(
        report: ToolPolicyCoherenceReport,
        catalogFingerprint: String,
        logger: Logger?
    ) {
        guard let logger else { return }
        if catalogFingerprint != self.catalogFingerprint {
            self.catalogFingerprint = catalogFingerprint
            emittedKeys.removeAll()
        }
        for issue in report.issues {
            guard emittedKeys.insert(issue.dedupeKey).inserted else { continue }
            let fixIt = issue.fixItConfigKey(profileID: report.profileID)
            switch issue.kind {
            case .unknownEntry:
                logger.warning(
                    "Tool policy coherence: unknown entry '\(issue.ruleToken)' in \(issue.scope.displayLabel) (\(fixIt)); \(issue.detail)"
                )
            case .shadowedAllow:
                let denyList = issue.shadowedBy.joined(separator: ", ")
                logger.warning(
                    "Tool policy coherence: shadowed allow '\(issue.ruleToken)' in \(issue.scope.displayLabel) (\(fixIt)); shadowed by [\(denyList)]. \(issue.detail)"
                )
            case .emptyGroup:
                logger.warning(
                    "Tool policy coherence: empty group '\(issue.ruleToken)' in \(issue.scope.displayLabel) (\(fixIt)); \(issue.detail)"
                )
            case .grantInactiveWithoutOptIn:
                logger.info(
                    "Tool policy coherence: grant '\(issue.ruleToken)' inactive without opt-in in \(issue.scope.displayLabel) (\(fixIt)); \(issue.detail)"
                )
            }
        }
    }

    func resetForTesting() {
        emittedKeys.removeAll()
        catalogFingerprint = ""
    }
}
