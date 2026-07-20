import EasyJSON
import Foundation
import SwiftAgentKit

struct SkillWorkshopToolProvider: ToolProvider, ToolDescriptorHinting {
    static let toolName = "skill_workshop"

    private let service: SkillWorkshopService
    private let conversationID: UUID?

    var name: String { "SkillWorkshop" }
    var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.toolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
        ]
    }

    init(service: SkillWorkshopService, conversationID: UUID?) {
        self.service = service
        self.conversationID = conversationID
    }

    func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.toolName,
                description: """
Propose or manage workspace skill updates. Route facts and preferences to memory; use this for multi-step repeatable procedures only. Actions: suggest (queue a pending proposal), apply (write a pending proposal to skills/), reject, list, inspect, status. Every suggest is scanned; critical findings quarantine the proposal and block apply.
""",
                parameters: [
                    .init(name: "action", description: "One of: suggest, apply, reject, list, inspect, status", type: "string", required: true),
                    .init(name: "reason", description: "Human-readable rationale (required for suggest)", type: "string", required: false),
                    .init(name: "proposal_id", description: "Proposal UUID for apply, reject, inspect", type: "string", required: false),
                    .init(name: "status", description: "Optional filter for list: pending, applied, rejected, quarantined", type: "string", required: false),
                    .init(name: "change", description: "Change payload for suggest: action (create|append|replace), skill_name, title, description, body, section_name, old_text", type: "object", required: false),
                ],
                type: .function
            ),
        ]
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        let action = extractString(from: toolCall.arguments, key: "action")?.lowercased() ?? ""
        do {
            switch action {
            case "suggest":
                let reason = extractString(from: toolCall.arguments, key: "reason") ?? ""
                guard let change = parseChange(from: toolCall.arguments) else {
                    return failure(toolCall, error: "change object required for suggest")
                }
                let result = try await service.suggest(reason: reason, change: change, sessionID: conversationID)
                let suffix = result.deduplicated ? " (deduplicated existing proposal)" : ""
                return success(
                    toolCall,
                    content: "proposal_id=\(result.proposal.id.uuidString) status=\(result.proposal.status.rawValue)\(suffix)"
                )
            case "apply":
                guard let id = parseUUID(from: toolCall.arguments, key: "proposal_id") else {
                    return failure(toolCall, error: "proposal_id required for apply")
                }
                let applied = try await service.apply(proposalID: id)
                return success(toolCall, content: "applied proposal_id=\(applied.id.uuidString) skill=\(applied.change.skillName)")
            case "reject":
                guard let id = parseUUID(from: toolCall.arguments, key: "proposal_id") else {
                    return failure(toolCall, error: "proposal_id required for reject")
                }
                let rejected = try await service.reject(proposalID: id)
                return success(toolCall, content: "rejected proposal_id=\(rejected.id.uuidString)")
            case "list":
                let statusFilter = extractString(from: toolCall.arguments, key: "status").flatMap(SkillWorkshopProposalStatus.init(rawValue:))
                let proposals = try await service.list(status: statusFilter)
                let rendered = proposals.map { "\($0.id.uuidString) status=\($0.status.rawValue) skill=\($0.change.skillName)" }.joined(separator: "\n")
                return success(toolCall, content: rendered.isEmpty ? "No proposals." : rendered)
            case "inspect":
                guard let id = parseUUID(from: toolCall.arguments, key: "proposal_id") else {
                    return failure(toolCall, error: "proposal_id required for inspect")
                }
                let proposal = try await service.inspect(proposalID: id)
                return success(toolCall, content: renderInspect(proposal))
            case "status":
                let counts = try await service.statusCounts()
                let rendered = SkillWorkshopProposalStatus.allCases
                    .map { "\($0.rawValue)=\(counts[$0, default: 0])" }
                    .joined(separator: " ")
                return success(toolCall, content: rendered)
            default:
                return failure(toolCall, error: "Unknown action: \(action)")
            }
        } catch SkillWorkshopServiceError.proposalQuarantined(let id) {
            return failure(toolCall, error: "Proposal \(id.uuidString) is quarantined and cannot be applied")
        } catch SkillWorkshopServiceError.applyBlockedByScan {
            return failure(toolCall, error: "Apply blocked by critical scan findings; proposal quarantined")
        } catch SkillWorkshopServiceError.proposalNotPending(let id) {
            return failure(toolCall, error: "Proposal \(id.uuidString) is not pending")
        } catch SkillWorkshopServiceError.emptyReason {
            return failure(toolCall, error: "reason is required for suggest")
        } catch SkillWorkshopServiceError.invalidChange(let message) {
            return failure(toolCall, error: message)
        } catch SkillWorkshopStoreError.proposalNotFound(let id) {
            return failure(toolCall, error: "Proposal not found: \(id.uuidString)")
        } catch SkillWorkshopWriterError.invalidSkillName(let raw) {
            return failure(toolCall, error: "Invalid skill name: \(raw)")
        } catch SkillWorkshopWriterError.oldTextNotFound {
            return failure(toolCall, error: "old_text not found in target skill")
        } catch {
            return failure(toolCall, error: String(describing: error))
        }
    }

    private func renderInspect(_ proposal: SkillWorkshopProposal) -> String {
        var lines = [
            "id=\(proposal.id.uuidString)",
            "status=\(proposal.status.rawValue)",
            "skill=\(proposal.change.skillName)",
            "action=\(proposal.change.action.rawValue)",
            "reason=\(proposal.reason)",
        ]
        if let quarantine = proposal.quarantineReason {
            lines.append("quarantine_reason=\(quarantine)")
        }
        if !proposal.scanFindings.isEmpty {
            lines.append("scan_findings=\(proposal.scanFindings.map(\.ruleID).joined(separator: ","))")
        }
        lines.append("body_preview=\(String(proposal.change.body.prefix(200)))")
        return lines.joined(separator: "\n")
    }

    private func parseChange(from arguments: JSON) -> SkillWorkshopChange? {
        guard case .object(let dict) = arguments,
              case .object(let changeObj)? = dict["change"] else { return nil }
        guard let actionRaw = jsonString(changeObj["action"]),
              let action = SkillWorkshopChangeAction(rawValue: actionRaw) else { return nil }
        guard let skillName = jsonString(changeObj["skill_name"]),
              let title = jsonString(changeObj["title"]),
              let description = jsonString(changeObj["description"]),
              let body = jsonString(changeObj["body"]) else { return nil }
        return SkillWorkshopChange(
            action: action,
            skillName: skillName,
            title: title,
            description: description,
            body: body,
            sectionName: jsonString(changeObj["section_name"]),
            oldText: jsonString(changeObj["old_text"])
        )
    }

    private func parseUUID(from arguments: JSON, key: String) -> UUID? {
        guard let raw = extractString(from: arguments, key: key) else { return nil }
        return UUID(uuidString: raw)
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments else { return nil }
        return jsonString(dict[key])
    }

    private func jsonString(_ value: JSON?) -> String? {
        guard let value else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    private func success(_ toolCall: ToolCall, content: String) -> ToolResult {
        ToolResult(
            success: true,
            content: content,
            metadata: .object(["source": .string("skill_workshop")]),
            toolCallId: toolCall.id
        )
    }

    private func failure(_ toolCall: ToolCall, error: String) -> ToolResult {
        ToolResult(
            success: false,
            content: "",
            metadata: .object(["source": .string("skill_workshop")]),
            toolCallId: toolCall.id,
            error: error
        )
    }
}
