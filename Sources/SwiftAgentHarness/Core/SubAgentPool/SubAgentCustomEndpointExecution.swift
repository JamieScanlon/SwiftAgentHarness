import Foundation
import Logging

struct CustomEndpointBinding: Sendable, Equatable {
    var url: URL
    var method: String
    var authHeaderName: String?
    var authHeaderValue: String?
    var timeoutSeconds: TimeInterval

    init(
        url: URL,
        method: String = "POST",
        authHeaderName: String? = nil,
        authHeaderValue: String? = nil,
        timeoutSeconds: TimeInterval = 120
    ) {
        self.url = url
        self.method = method
        self.authHeaderName = authHeaderName
        self.authHeaderValue = authHeaderValue
        self.timeoutSeconds = timeoutSeconds
    }
}

struct SubAgentCustomEndpointConfiguration: Sendable {
    var bindingsByDelegateToolName: [String: CustomEndpointBinding]

    static let empty = SubAgentCustomEndpointConfiguration(bindingsByDelegateToolName: [:])

    func binding(for delegateToolName: String) -> CustomEndpointBinding? {
        bindingsByDelegateToolName[delegateToolName]
    }

    static func loadFromPromptConfigBundle(logger: Logger? = nil) -> SubAgentCustomEndpointConfiguration {
        guard let data = PromptConfigBundleResource.data(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return fromPromptConfigRoot(json, logger: logger)
    }

    static func fromPromptConfigRoot(_ json: [String: Any], logger: Logger? = nil) -> SubAgentCustomEndpointConfiguration {
        guard let raw = json["subAgentCustomEndpoints"] as? [String: [String: Any]] else {
            return .empty
        }
        var bindings: [String: CustomEndpointBinding] = [:]
        for (toolName, entry) in raw {
            guard let urlString = entry["url"] as? String,
                  let url = URL(string: urlString) else {
                logger?.warning("Skipping custom endpoint for \(toolName): invalid url")
                continue
            }
            let method = (entry["method"] as? String)?.uppercased() ?? "POST"
            let authHeaderName = entry["authHeaderName"] as? String
            let authHeaderValue = (entry["authHeaderValue"] as? String)
                ?? ((entry["authHeaderValueEnv"] as? String).flatMap { ProcessInfo.processInfo.environment[$0] })
            let timeout = (entry["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120
            bindings[toolName] = CustomEndpointBinding(
                url: url,
                method: method,
                authHeaderName: authHeaderName,
                authHeaderValue: authHeaderValue,
                timeoutSeconds: timeout
            )
        }
        return SubAgentCustomEndpointConfiguration(bindingsByDelegateToolName: bindings)
    }
}

struct CustomEndpointDelegateResponse: Sendable, Equatable {
    var content: String
    var usage: DelegateCompletionUsagePayload?
}

protocol CustomEndpointDelegateExecuting: Sendable {
    func invoke(
        endpoint: CustomEndpointBinding,
        instructions: String,
        lifecycleID: String,
        toolCallID: String?
    ) async throws -> CustomEndpointDelegateResponse
}

struct URLSessionCustomEndpointDelegateExecutor: CustomEndpointDelegateExecuting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func invoke(
        endpoint: CustomEndpointBinding,
        instructions: String,
        lifecycleID: String,
        toolCallID: String?
    ) async throws -> CustomEndpointDelegateResponse {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = endpoint.method
        request.timeoutInterval = endpoint.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeaderName = endpoint.authHeaderName,
           let authHeaderValue = endpoint.authHeaderValue,
           !authHeaderName.isEmpty,
           !authHeaderValue.isEmpty {
            request.setValue(authHeaderValue, forHTTPHeaderField: authHeaderName)
        }
        let body: [String: String?] = [
            "instructions": instructions,
            "toolCallId": toolCallID,
            "lifecycleId": lifecycleID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubAgentPoolError.operationFailed(reason: "custom_endpoint_invalid_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SubAgentPoolError.operationFailed(reason: "custom_endpoint_http_\(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubAgentPoolError.operationFailed(reason: "custom_endpoint_invalid_json")
        }
        let content = (json["content"] as? String) ?? ""
        let usage = parseUsage(json["usage"] as? [String: Any])
        return CustomEndpointDelegateResponse(content: content, usage: usage)
    }

    private func parseUsage(_ raw: [String: Any]?) -> DelegateCompletionUsagePayload? {
        guard let raw else { return nil }
        let promptTokens = raw["promptTokens"] as? Int
        let completionTokens = raw["completionTokens"] as? Int
        let totalTokens = raw["totalTokens"] as? Int
        let costUSD = raw["costUSD"] as? Double
        guard promptTokens != nil || completionTokens != nil || totalTokens != nil || costUSD != nil else {
            return nil
        }
        return DelegateCompletionUsagePayload(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            costUSD: costUSD
        )
    }
}
