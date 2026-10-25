import Foundation

/// A live specialist session as the user's surfaces see it.
public struct ComputerUseSessionStatus: Sendable, Codable, Equatable {
    public var lifecycleID: String
    public var target: String
    public var step: Int
    public var maxSteps: Int
    public var takenOver: Bool
}

/// What is waiting on the user, and what is running, for one conversation.
public struct ComputerUseControlStatus: Sendable, Codable, Equatable {
    public var pending: [ComputerUsePendingRequest]
    public var sessions: [ComputerUseSessionStatus]
}

public enum ComputerUseRequestResolutionResult: Sendable, Equatable {
    case resolved
    case notFound
    /// An answer to a handoff, or a hand-back for a question.
    case wrongKind
}

/// The user's controls over the computer-use specialists working for a conversation. Only the user's surfaces
/// reach these; no model-facing tool does. Get one from ``HarnessRuntimeSession/computerUseControl``.
public struct ComputerUseControlService: Sendable {
    let installation: ComputerUseInstallation

    public func status(conversationID: UUID) async -> ComputerUseControlStatus {
        let pending = await installation.coordinator?.pending(conversationID: conversationID) ?? []
        var sessions: [ComputerUseSessionStatus] = []
        for entry in await installation.sessions.entries(parent: conversationID) where await entry.session.terminalReason == nil {
            sessions.append(ComputerUseSessionStatus(
                lifecycleID: entry.lifecycleID,
                target: entry.targetLabel,
                step: await entry.session.stepCount,
                maxSteps: entry.session.lease.budgets.maxSteps,
                takenOver: await entry.session.isTakeoverActive
            ))
        }
        return ComputerUseControlStatus(pending: pending, sessions: sessions)
    }

    public func resolve(requestID: String, conversationID: UUID, resolution: ComputerUseRequestResolution) async -> ComputerUseRequestResolutionResult {
        guard let coordinator = installation.coordinator,
              await coordinator.pending(conversationID: conversationID).contains(where: { $0.id == requestID })
        else { return .notFound }
        return await coordinator.resolve(id: requestID, conversationID: conversationID, resolution: resolution) ? .resolved : .wrongKind
    }

    /// The per-conversation kill switch. Pending questions and handoffs from the stopped sessions are declined
    /// so their specialists unblock and finish. Returns the stopped sessions' lifecycle ids.
    public func stop(conversationID: UUID) async -> [String] {
        var stopped: [String] = []
        for entry in await installation.sessions.entries(parent: conversationID) where await entry.session.terminalReason == nil {
            await entry.session.stop()
            stopped.append(entry.lifecycleID)
        }
        if let coordinator = installation.coordinator {
            for request in await coordinator.pending(conversationID: conversationID)
            where request.lifecycleID.map(stopped.contains) ?? false {
                await coordinator.resolve(id: request.id, conversationID: conversationID, resolution: .declined)
            }
        }
        return stopped
    }

    /// Takes over (or hands back) the conversation's live sessions, or just `lifecycleID`'s. Returns the lifecycle
    /// ids it changed.
    public func setTakeover(_ on: Bool, conversationID: UUID, lifecycleID: String?) async throws -> [String] {
        var changed: [String] = []
        for entry in await installation.sessions.entries(parent: conversationID)
        where lifecycleID.map({ $0 == entry.lifecycleID }) ?? true {
            guard await entry.session.terminalReason == nil else { continue }
            try await entry.session.setTakeover(on)
            changed.append(entry.lifecycleID)
        }
        return changed
    }
}
