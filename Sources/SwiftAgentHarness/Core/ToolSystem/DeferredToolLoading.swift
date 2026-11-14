import EasyJSON
import Foundation
import SwiftAgentKit

/// A deferred tool `tool_search` can load: one the conversation's policy would advertise, held back until the
/// model asks for it.
struct DeferredToolCandidate: Sendable, Equatable {
    var name: String
    var description: String
    var searchHint: String?
}

/// Deferred tool loading. A tool tagged `defer-loading` stays out of the model's tool list, keeping its schema out
/// of the prompt, until `tool_search` loads it for the conversation. Then it is offered like any other tool.
/// Policy still decides first: only a tool the conversation would otherwise be offered can be found or loaded.
enum DeferredToolLoading {
    static let searchToolName = "tool_search"
    static let metadataKey = "loadedDeferredToolNames"
    static let deferLoadingTagRawValue = "defer-loading"
    static let searchHintTagPrefix = "search-hint:"

    static var deferLoadingTag: ToolPolicyTag { ToolPolicyTag(rawValue: deferLoadingTagRawValue) }

    /// Keywords `tool_search` matches besides the name and description.
    static func searchHintTag(_ phrase: String) -> ToolPolicyTag {
        ToolPolicyTag(rawValue: searchHintTagPrefix + phrase)
    }

    static func searchHint(fromPolicyTags tags: [ToolPolicyTag]) -> String? {
        let hints = tags.map(\.rawValue).filter { $0.hasPrefix(searchHintTagPrefix) }.map { String($0.dropFirst(searchHintTagPrefix.count)) }
        return hints.isEmpty ? nil : hints.joined(separator: " ")
    }

    static func loadedToolNames(from metadata: JSON?) -> Set<String> {
        guard case .object(let object)? = metadata, case .array(let values)? = object[metadataKey] else { return [] }
        return Set(values.compactMap { value in
            if case .string(let name) = value { return name }
            return nil
        })
    }

    /// Adds `names` to the loaded set (sorted for stable persistence).
    static func mergingLoadedToolNames(_ names: Set<String>, into metadata: JSON?) -> JSON? {
        var root: [String: JSON] = [:]
        if case .object(let object)? = metadata { root = object }
        let merged = loadedToolNames(from: metadata).union(names)
        root[metadataKey] = .array(merged.sorted().map { .string($0) })
        return .object(root)
    }

    /// Applies deferral to one turn's availability decisions. A deferred tool the conversation would be offered
    /// becomes `deferredUntilLoaded` unless loaded. `tool_search` is offered only while such a tool exists. If
    /// policy blocks `tool_search` itself, nothing is deferred, because those tools would otherwise be unreachable.
    static func resolve(
        _ decisions: [(entry: ToolRegistryEntry, decision: ToolAvailabilityDecision)],
        conversation: ModelConversation
    ) -> [(entry: ToolRegistryEntry, decision: ToolAvailabilityDecision)] {
        let loaded = loadedToolNames(from: conversation.metadata)
        let searchAdvertised = decisions.contains { $0.entry.name == searchToolName && $0.decision.isAdvertisedToModel }
        var deferredAny = false
        var resolved = decisions.map { pair -> (entry: ToolRegistryEntry, decision: ToolAvailabilityDecision) in
            guard searchAdvertised,
                  pair.entry.policyTags.contains(.deferLoading),
                  pair.decision.isAdvertisedToModel,
                  !loaded.contains(pair.entry.name)
            else { return pair }
            deferredAny = true
            return (pair.entry, pair.decision.deferredUntilLoaded())
        }
        if !deferredAny {
            resolved = resolved.map { pair in
                guard pair.entry.name == searchToolName, pair.decision.isAdvertisedToModel else { return pair }
                return (pair.entry, pair.decision.deferredUntilLoaded())
            }
        }
        return resolved
    }

    static func candidates(_ decisions: [(entry: ToolRegistryEntry, decision: ToolAvailabilityDecision)]) -> [DeferredToolCandidate] {
        decisions
            .filter { $0.decision.blockReason == .deferredUntilLoaded && $0.entry.name != searchToolName }
            .map { DeferredToolCandidate(name: $0.entry.name, description: $0.entry.description, searchHint: $0.entry.searchHint) }
            .sorted { $0.name < $1.name }
    }

    /// Candidates matching `query`, best first. An exact name wins; otherwise each query word scores 3 in the
    /// name, 2 in the search hint, and 1 in the description.
    static func rank(_ candidates: [DeferredToolCandidate], query: String, limit: Int) -> [DeferredToolCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = candidates.first(where: { $0.name.lowercased() == trimmed }) { return [exact] }
        let words = Set(tokens(trimmed).filter { $0.count >= 3 })
        guard !words.isEmpty else { return [] }
        let scored = candidates.compactMap { candidate -> (DeferredToolCandidate, Int)? in
            let name = Set(tokens(candidate.name.lowercased()))
            let hint = Set(tokens(candidate.searchHint?.lowercased() ?? ""))
            let description = Set(tokens(candidate.description.lowercased()))
            let score = words.reduce(0) { total, word in
                total + (name.contains(word) ? 3 : 0) + (hint.contains(word) ? 2 : 0) + (description.contains(word) ? 1 : 0)
            }
            return score > 0 ? (candidate, score) : nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .prefix(max(1, limit))
            .map { $0.0 }
    }

    private static func tokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Each conversation's deferred-tool candidates from its latest turn snapshot, for `tool_search` to search.
actor DeferredToolCatalog {
    private var candidates: [UUID: [DeferredToolCandidate]] = [:]

    func setCandidates(_ candidates: [DeferredToolCandidate], for conversationID: UUID) {
        self.candidates[conversationID] = candidates.isEmpty ? nil : candidates
    }

    func candidates(for conversationID: UUID) -> [DeferredToolCandidate] {
        candidates[conversationID] ?? []
    }
}

/// `tool_search`: finds deferred tools and loads them into the conversation, so their schemas reach the prompt only
/// when the model asks.
struct ToolSearchToolProvider: ToolProvider {
    let resolveConversationID: @Sendable () -> UUID?
    let catalog: DeferredToolCatalog
    /// Records the names as loaded for the conversation.
    let load: @Sendable (UUID, [String]) async -> Void

    static let defaultLimit = 5

    var name: String { "ToolSearchToolProvider" }

    func availableTools() async -> [ToolDefinition] {
        [Self.definition]
    }

    static let definition = ToolDefinition(
        name: DeferredToolLoading.searchToolName,
        description: """
            Find tools that are not loaded yet and load them. Some tools are kept out of your tool list until you \
            search for them, including ones for operating desktop apps. Search when none of your tools fits the job. \
            Prefer a loaded tool that does the job directly. Matching tools become callable on your next step.
            """,
        parameters: [
            ToolDefinition.Parameter(
                name: "query",
                description: "What you need to do, in a few words, such as \"click through a desktop app\". An exact tool name loads just that tool.",
                type: "string",
                required: true
            ),
            ToolDefinition.Parameter(
                name: "max_results",
                description: "Most tools to load. Default 5.",
                type: "integer",
                required: false
            ),
        ],
        type: .function
    )

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard toolCall.name == DeferredToolLoading.searchToolName else {
            return ToolResult(success: false, content: "", toolCallId: toolCall.id, error: "Unknown tool \(toolCall.name)")
        }
        let query = Self.string("query", in: toolCall.arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return ToolResult(success: false, content: "Give a query describing the tool you need.", toolCallId: toolCall.id, error: "empty query")
        }
        guard let conversationID = resolveConversationID() else {
            return ToolResult(success: false, content: "No conversation to load tools into.", toolCallId: toolCall.id, error: "no conversation")
        }
        let limit = Self.int("max_results", in: toolCall.arguments) ?? Self.defaultLimit
        let matches = DeferredToolLoading.rank(await catalog.candidates(for: conversationID), query: query, limit: limit)
        guard !matches.isEmpty else {
            return ToolResult(success: true, content: "No tools match \"\(query)\". Use the tools you have.", toolCallId: toolCall.id)
        }
        await load(conversationID, matches.map(\.name))
        let lines = matches.map { "- \($0.name): \(Self.firstSentence($0.description))" }
        return ToolResult(
            success: true,
            content: "Loaded \(matches.count == 1 ? "1 tool" : "\(matches.count) tools"). Call them on your next step.\n" + lines.joined(separator: "\n"),
            toolCallId: toolCall.id
        )
    }

    func effectClass(for definition: ToolDefinition) async -> ToolEffectClass { .readOnly }
    func executionParallelHint(for definition: ToolDefinition) async -> ToolExecutionParallelHint { .serialOnly }

    private static func string(_ key: String, in arguments: JSON) -> String? {
        guard case .object(let fields) = arguments, case .string(let value)? = fields[key] else { return nil }
        return value
    }

    private static func int(_ key: String, in arguments: JSON) -> Int? {
        guard case .object(let fields) = arguments else { return nil }
        switch fields[key] {
        case .integer(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int(value)
        case .string(let value)?: return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let end = flat.range(of: ". ") else { return flat }
        return String(flat[..<end.lowerBound]) + "."
    }
}
