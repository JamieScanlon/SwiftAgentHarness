import CryptoKit
import Foundation

enum SystemPromptAssemblyFingerprint {
    /// SHA256 hex digest of canonical assembly inputs (profile + session policy knobs).
    static func hexDigest(
        resolved: ResolvedModeProfile,
        strictAgentHarnessPrompts: Bool,
        includeAgentSkills: Bool,
        includeDateTime: Bool,
        toolPolicySignature: String,
        routingPolicyTools: [String],
        routingPolicySkills: [String],
        memorySnapshotGeneration: Int? = nil,
        tier1MemorySectionContent: String? = nil
    ) -> String {
        let tools = routingPolicyTools.sorted().joined(separator: ",")
        let skills = routingPolicySkills.sorted().joined(separator: ",")
        let sliceSig = modeProfileSliceSignature(resolved)
        let memoryGen = memorySnapshotGeneration.map(String.init) ?? "-"
        let tier1Sig: String = {
            guard let tier1 = tier1MemorySectionContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tier1.isEmpty else { return "-" }
            return "len=\(tier1.count):prefix=\(String(tier1.prefix(256)))"
        }()
        let canonical =
            """
            modeId=\(resolved.id)
            seed=\(resolved.builtInSeedVersion)
            assembly=\(resolved.assemblyKind.rawValue)
            strictHarness=\(strictAgentHarnessPrompts)
            skills=\(includeAgentSkills)
            date=\(includeDateTime)
            toolPolicy=\(toolPolicySignature)
            routingTools=\(tools)
            routingSkills=\(skills)
            modeSlices=\(sliceSig)
            memorySnapshotGeneration=\(memoryGen)
            tier1Memory=\(tier1Sig)
            """
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func modeProfileSliceSignature(_ r: ResolvedModeProfile) -> String {
        let toolAllowSig = r.tools.allow.map { $0.sorted().joined(separator: ",") } ?? "*"
        let toolDenySig = r.tools.deny.sorted().joined(separator: ",")
        let toolApprovalSig = r.tools.approvalPolicy?.rawValue ?? "-"
        let skillAllowSig = r.skills.allow.map { $0.sorted().joined(separator: ",") } ?? "*"
        let skillDenySig = r.skills.deny.sorted().joined(separator: ",")
        let directiveSig = r.context.modeDirective.map { String($0.prefix(256)) } ?? "-"
        let ctxSkills = r.context.includeSkills.map { String($0) } ?? "-"
        let ctxGuidance = r.context.includeToolGuidance.map { String($0) } ?? "-"
        let compactionSig = r.context.compactionLevel ?? "-"
        let memorySig = r.context.memoryInjection.map { String($0.prefix(128)) } ?? "-"
        let sectionOverridesSig = r.context.sectionOverrides
            .keys
            .sorted()
            .map { key in
                let value = r.context.sectionOverrides[key] ?? ""
                return "\(key)=\(String(value.prefix(256)))"
            }
            .joined(separator: ",")
        let suppressSig = r.context.suppressSections.sorted().joined(separator: ",")
        let runtimeTerminationSig: String = {
            guard let termination = r.runtime.termination else { return "-" }
            let recovery = termination.recovery.map { rec in
                "\(rec.strategy.rawValue),\(rec.rollbackStalledTurn),\(rec.maxAttempts),\(rec.reminder.rawValue)"
            } ?? "-"
            return "\(termination.policy.rawValue),\(recovery)"
        }()
        let runtimeSig = [
            r.runtime.maxIterations.map(String.init) ?? "-",
            r.runtime.stopOnApprovalRequest.map(String.init) ?? "-",
            runtimeTerminationSig,
        ].joined(separator: "|")
        let modelSig = [r.model.query ?? "-", r.model.fallback ?? "-"].joined(separator: "|")
        let subAllowSig = r.subAgents.allow.map {
            let lowered = Set($0.map { $0.lowercased() })
            if lowered.contains("*") {
                return "*"
            }
            return lowered.sorted().joined(separator: ",")
        } ?? "-"
        let subSig = [
            subAllowSig,
            r.subAgents.maxDepth.map(String.init) ?? "-",
            r.subAgents.childModeOnSpawnProfileId ?? "-",
        ].joined(separator: "|")
        return [
            "tools:\(toolAllowSig)|\(toolDenySig)|\(toolApprovalSig)",
            "skills:\(skillAllowSig)|\(skillDenySig)",
            "ctx:\(directiveSig)|skills:\(ctxSkills)|tg:\(ctxGuidance)|cmp:\(compactionSig)|mem:\(memorySig)|sec:\(sectionOverridesSig)|sup:\(suppressSig)",
            "rt:\(runtimeSig)",
            "mdl:\(modelSig)",
            "sub:\(subSig)",
        ].joined(separator: ";")
    }
}
