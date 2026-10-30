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

/// A run's audit mark and when its images expire.
public struct ComputerUseAuditStatus: Sendable, Codable, Equatable {
    public var lifecycleID: String
    public var auditMarked: Bool
    /// `false` while the run is live: the mark takes effect at release.
    public var released: Bool
    /// `nil` while held.
    public var expiresAt: Date?
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
                maxSteps: entry.session.lease.budgets.steps,
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

    /// The conversation's recent replays, newest first.
    public func replays(conversationID: UUID) async -> [ComputerUseReplaySummary] {
        await installation.replays.summaries(parent: conversationID)
    }

    public func replay(conversationID: UUID, lifecycleID: String) async -> ComputerUseReplay? {
        await installation.replays.entry(parent: conversationID, lifecycleID: lifecycleID)?.replay
    }

    /// One thumbnail the replay lists; anything else in the blob store stays out of reach.
    public func replayThumbnail(conversationID: UUID, lifecycleID: String, observationID: ObservationID) async -> PresentationImage? {
        guard let entry = await installation.replays.entry(parent: conversationID, lifecycleID: lifecycleID),
              let thumbnail = entry.replay.thumbnails.first(where: { $0.observationID == observationID }),
              let data = try? entry.access.load(thumbnail.blobID)
        else { return nil }
        return PresentationImage(
            data: data,
            mediaType: thumbnail.mediaType,
            width: thumbnail.width,
            height: thumbnail.height,
            alt: "Observation \(observationID)"
        )
    }

    /// Marks a run for audit, or removes the mark. A live run takes the mark at release; a released run's images
    /// move to the audit retention (or back to the normal one) right away. `nil` when the conversation has no
    /// such run.
    public func setAuditMark(_ marked: Bool, conversationID: UUID, lifecycleID: String) async -> ComputerUseAuditStatus? {
        let live = await installation.sessions.entries(parent: conversationID)
        if live.contains(where: { $0.lifecycleID == lifecycleID }) {
            await installation.blobs.setAuditMark(marked, parent: conversationID, lifecycleID: lifecycleID)
            return ComputerUseAuditStatus(lifecycleID: lifecycleID, auditMarked: marked, released: false, expiresAt: nil)
        }
        guard let entry = await installation.replays.entry(parent: conversationID, lifecycleID: lifecycleID) else { return nil }
        let expiresAt = installation.retention.expiry(releasedAt: entry.releasedAt, auditMarked: marked)
        for blobID in entry.blobIDs {
            try? entry.access.setExpiry(blobID, expiresAt)
        }
        await installation.replays.updateRetention(parent: conversationID, lifecycleID: lifecycleID, auditMarked: marked, expiresAt: expiresAt)
        return ComputerUseAuditStatus(lifecycleID: lifecycleID, auditMarked: marked, released: true, expiresAt: expiresAt)
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
