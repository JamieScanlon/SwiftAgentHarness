import EasyJSON
import Foundation
import Logging
import SwiftAgentKitACP

public enum HarnessACPManagerBootstrap {
    public static func initialize(
        manager: ACPManager,
        configFileURL: URL,
        logger: Logger? = nil
    ) async throws -> [String: SubAgentACPClientDelegateBox] {
        let config = try ACPConfigHelper.parseACPConfig(fileURL: configFileURL)
        var delegateBoxes: [String: SubAgentACPClientDelegateBox] = [:]
        var clients: [ACPClient] = []

        for bootCall in config.agentBootCalls {
            guard let command = bootCall.command else {
                logger?.error("[HarnessACPManagerBootstrap] skipping ACP agent name=\(bootCall.name) missing command")
                continue
            }
            let box = SubAgentACPClientDelegateBox()
            delegateBoxes[bootCall.name] = box
            var environment = environmentDictionary(from: config.globalEnvironment)
            environment.merge(environmentDictionary(from: bootCall.environment), uniquingKeysWith: { _, new in new })
            do {
                let client = try await ACPClient.boot(
                    name: bootCall.name,
                    command: command,
                    arguments: bootCall.arguments,
                    environment: environment,
                    useShell: bootCall.useShell,
                    delegate: box,
                    clientCapabilities: ACPClient.defaultClientCapabilities(
                        advertiseTerminal: bootCall.advertiseTerminal
                    ),
                    toolCallTimeout: bootCall.toolCallTimeout ?? config.toolCallTimeout,
                    staticMcpBootServers: config.mcpBootServers,
                    logger: logger
                )
                clients.append(client)
            } catch {
                logger?.error(
                    "[HarnessACPManagerBootstrap] failed to boot ACP agent name=\(bootCall.name) error=\(String(describing: error))"
                )
            }
        }

        try await manager.initialize(clients: clients)
        return delegateBoxes
    }

    private static func environmentDictionary(from json: JSON) -> [String: String] {
        guard case .object(let dict) = json else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if case .string(let string) = value {
                result[key] = string
            }
        }
        return result
    }
}
