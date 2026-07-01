import Foundation

/// Tracks in-flight `message` tool calls and emits incremental visible text from streaming arguments.
struct MessageToolStreamingAccumulator: Sendable {
    private var toolNamesByCallID: [String: String] = [:]
    private var argumentBuffers: [String: String] = [:]
    private var emittedVisibleText: [String: String] = [:]

    mutating func registerToolCall(id: String?, name: String?) {
        guard let name, !name.isEmpty else { return }
        if let id, !id.isEmpty {
            toolNamesByCallID[id] = name
        } else {
            toolNamesByCallID[name] = name
        }
    }

    mutating func ingestArgumentsFragment(id: String?, name: String?, fragment: String) -> String? {
        registerToolCall(id: id, name: name)
        guard let key = callKey(id: id, name: name), isMessageTool(key: key, name: name) else {
            return nil
        }
        guard !fragment.isEmpty else { return nil }
        argumentBuffers[key, default: ""] += fragment
        return emitSuffix(for: key)
    }

    mutating func ingestCompleted(id: String?, name: String?, arguments: String) -> String? {
        registerToolCall(id: id, name: name)
        guard let key = callKey(id: id, name: name), isMessageTool(key: key, name: name) else {
            return nil
        }
        let existing = argumentBuffers[key] ?? ""
        if arguments.count > existing.count {
            argumentBuffers[key] = arguments
        } else if existing.isEmpty, !arguments.isEmpty {
            argumentBuffers[key] = arguments
        }
        return emitSuffix(for: key)
    }

    private func callKey(id: String?, name: String?) -> String? {
        if let id, !id.isEmpty { return id }
        if let name, !name.isEmpty { return name }
        return nil
    }

    private func isMessageTool(key: String, name: String?) -> Bool {
        if let registered = toolNamesByCallID[key] {
            return registered == MessageToolArgumentsParser.toolName
        }
        return name == MessageToolArgumentsParser.toolName
    }

    private mutating func emitSuffix(for key: String) -> String? {
        guard let buffer = argumentBuffers[key],
              let visible = MessageToolArgumentsParser.visibleText(fromArgumentsFragment: buffer),
              !visible.isEmpty
        else {
            return nil
        }
        let previouslyEmitted = emittedVisibleText[key] ?? ""
        guard visible.count > previouslyEmitted.count, visible.hasPrefix(previouslyEmitted) else {
            if visible != previouslyEmitted, previouslyEmitted.isEmpty {
                emittedVisibleText[key] = visible
                return visible
            }
            return nil
        }
        let suffix = String(visible.dropFirst(previouslyEmitted.count))
        guard !suffix.isEmpty else { return nil }
        emittedVisibleText[key] = visible
        return suffix
    }
}
