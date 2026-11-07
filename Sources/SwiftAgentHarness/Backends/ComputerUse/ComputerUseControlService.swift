import Foundation

/// A live specialist session as the user's surfaces see it.
public struct ComputerUseSessionStatus: Sendable, Codable, Equatable {
    public var lifecycleID: String
    public var target: String
    public var step: Int
    public var maxSteps: Int
    public var takenOver: Bool
    /// Whether the target can serve a live view; ask for a link with ``ComputerUseControlService/liveView(conversationID:lifecycleID:)``.
    public var liveView: Bool
    /// Whether the target is someone's own screen, such as their Mac, which the user may be at.
    public var sharedScreen: Bool
}

/// What is waiting on the user, and what is running, for one conversation.
public struct ComputerUseControlStatus: Sendable, Codable, Equatable {
    public var pending: [ComputerUsePendingRequest]
    public var sessions: [ComputerUseSessionStatus]
}

/// A run's audit mark and when its images expire.
/// An image's bytes, for a route that serves them.
public struct ComputerUseImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String
    public var width: Int?
    public var height: Int?

    public init(data: Data, mediaType: String, width: Int? = nil, height: Int? = nil) {
        self.data = data
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}

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
                maxSteps: await entry.session.budgets.steps,
                takenOver: await entry.session.isTakeoverActive,
                liveView: entry.session.manifest.observerAccess != .none,
                sharedScreen: entry.session.manifest.humanPresence == .shared
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
    public func replayThumbnail(conversationID: UUID, lifecycleID: String, observationID: ObservationID) async -> ComputerUseImage? {
        guard let entry = await installation.replays.entry(parent: conversationID, lifecycleID: lifecycleID),
              let thumbnail = entry.replay.thumbnails.first(where: { $0.observationID == observationID }),
              let data = try? entry.access.load(thumbnail.blobID)
        else { return nil }
        return ComputerUseImage(data: data, mediaType: thumbnail.mediaType, width: thumbnail.width, height: thumbnail.height)
    }

    /// An image a live run's approval card cites by `blob://` ref. Only images the conversation's own live runs
    /// stored are served.
    public func runBlob(conversationID: UUID, blobID: String) async -> ConversationBlob? {
        guard let blobID = ConversationBlobAccess.normalizedID(blobID) else { return nil }
        for child in await installation.sessions.children(parent: conversationID) {
            guard await installation.blobs.holds(blobID, childConversationID: child),
                  let data = try? installation.readBlob?(blobID)
            else { continue }
            return ConversationBlob(data: data, mediaType: SessionBlobMIME.sniff(data: data, hint: nil), contentHash: blobID)
        }
        return nil
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
        let retention = installation.retention
        let ledger = installation.blobs
        // The replay's own reference, restated for a run rediscovered after a restart; the mark adds or drops its own.
        var expiries = await ledger.reference(
            entry.blobIDs, by: .replay(parent: conversationID, lifecycleID: lifecycleID),
            until: retention.expiry(releasedAt: entry.releasedAt, auditMarked: false)
        )
        expiries += await ledger.reference(
            entry.blobIDs, by: .audit(parent: conversationID, lifecycleID: lifecycleID),
            until: marked ? retention.expiry(releasedAt: entry.releasedAt, auditMarked: true) : nil
        )
        var latest: [String: Date] = [:]
        for expiry in expiries { latest[expiry.blobID] = expiry.expiresAt }
        for (blobID, date) in latest { try? entry.access.setExpiry(blobID, date) }
        let expiresAt = latest[entry.documentBlobID] ?? retention.expiry(releasedAt: entry.releasedAt, auditMarked: marked)
        await installation.replays.updateRetention(parent: conversationID, lifecycleID: lifecycleID, auditMarked: marked, expiresAt: expiresAt)
        return ComputerUseAuditStatus(lifecycleID: lifecycleID, auditMarked: marked, released: true, expiresAt: expiresAt)
    }

    /// A new live-view link to a live run. `nil` when the conversation has no such live run or its target serves no
    /// live view. Each call mints a new short-lived link. An observer link is for someone other than the user to
    /// watch: it never carries input, and shows nothing while the user has control.
    public func liveView(conversationID: UUID, lifecycleID: String, role: DisplayLiveViewRole = .user) async throws -> DisplayLiveView? {
        guard let session = await liveSession(conversationID: conversationID, lifecycleID: lifecycleID) else { return nil }
        return try await session.liveView(role: role)
    }

    /// Ends a live run's observers and revokes its observer links; the user's are kept. `false` when the
    /// conversation has no such live run.
    public func endObservers(conversationID: UUID, lifecycleID: String) async throws -> Bool {
        guard let session = await liveSession(conversationID: conversationID, lifecycleID: lifecycleID) else { return false }
        try await session.endObservers()
        return true
    }

    /// The viewers connected to a live run's live view. `nil` when the conversation has no such live run.
    public func liveConnections(conversationID: UUID, lifecycleID: String) async throws -> [DisplayLiveViewConnection]? {
        guard let session = await liveSession(conversationID: conversationID, lifecycleID: lifecycleID) else { return nil }
        return try await session.liveConnections()
    }

    /// Ends one viewer's connection to a live run's live view, or revokes that link if unused. `false` when the
    /// conversation has no such live run or link.
    public func revokeLiveView(conversationID: UUID, lifecycleID: String, linkID: UUID) async throws -> Bool {
        guard let session = await liveSession(conversationID: conversationID, lifecycleID: lifecycleID) else { return false }
        return try await session.revokeLiveView(linkID)
    }

    private func liveSession(conversationID: UUID, lifecycleID: String) async -> ComputerUseSession? {
        guard let entry = await installation.sessions.entries(parent: conversationID).first(where: { $0.lifecycleID == lifecycleID }),
              await entry.session.terminalReason == nil
        else { return nil }
        return entry.session
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
