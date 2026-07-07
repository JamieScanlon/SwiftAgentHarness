import Foundation
import SwiftAgentKit

public enum ConversationStreamPayloadAssembly {
    public static func streamingFinalPayload(from messages: [Message]) -> StreamingFinalPayload {
        let text = messages
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let media = messages.flatMap { message in
            message.images.map { image in
                StreamingMediaRef(
                    id: image.path ?? image.name,
                    kind: "image"
                )
            }
        }
        return StreamingFinalPayload(text: text, media: media)
    }
}

/// Demuxes decoded conversation topic events into a ``ConversationStreamConsumer``.
public actor ConversationStreamSurfaceDriver {
    public struct Configuration: Sendable, Equatable {
        public var commitWaitTimeoutMs: Int
        public var boundedTurnNotice: String

        public init(
            commitWaitTimeoutMs: Int = 500,
            boundedTurnNotice: String = "_(turn bounded)_"
        ) {
            self.commitWaitTimeoutMs = commitWaitTimeoutMs
            self.boundedTurnNotice = boundedTurnNotice
        }
    }

    private let configuration: Configuration
    private var knownMessageIDs: Set<UUID> = []
    private var turnActive = false
    private var currentRunID: UUID?
    private var pendingAssistantMessages: [Message] = []
    private var mediaLedger = MediaDeliveryLedger()
    private var baselineSeeded = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func consume(
        events: AsyncStream<DecodedConversationTopicEvent>,
        consumer: any ConversationStreamConsumer
    ) async {
        for await event in events {
            await handle(event, consumer: consumer)
        }
    }

    public func handle(
        _ event: DecodedConversationTopicEvent,
        consumer: any ConversationStreamConsumer
    ) async {
        switch event {
        case .partial(let partial, _, _, _, _):
            guard turnActive else { return }
            await consumer.ingest(partial)
        case .streamDone:
            guard turnActive else { return }
            await consumer.flushSegment()
        case .runtimeLifecycle(let payload, _, _):
            await handleRuntimeLifecycle(payload, consumer: consumer)
        case .committedMessages(let messages, _, _):
            ingestCommittedMessages(messages)
        case .surfaceIntent(let intent, _, _):
            guard turnActive else { return }
            await consumer.ingest(.surfaceIntent(intent))
        case .modelLifecycle, .checkpoint, .unknown:
            break
        }
    }

    // MARK: - Private

    private func handleRuntimeLifecycle(
        _ payload: RuntimeLifecycleEventPayload,
        consumer: any ConversationStreamConsumer
    ) async {
        switch payload.name {
        case .turnStarted:
            turnActive = true
            currentRunID = payload.runID
            pendingAssistantMessages = []
            mediaLedger.reset()
        case .modelCallCompleted:
            guard turnActive else { return }
            await consumer.flushSegment()
        case .turnCompleted, .turnBounded:
            guard turnActive else { return }
            await finalizeTurn(wasBounded: payload.name == .turnBounded, consumer: consumer)
        case .turnCancelled:
            guard turnActive else { return }
            await consumer.cancelTurn()
            resetTurnState()
        default:
            break
        }
    }

    private func ingestCommittedMessages(_ messages: [Message]) {
        if !baselineSeeded {
            for message in messages {
                knownMessageIDs.insert(message.id)
            }
            baselineSeeded = true
            return
        }

        let newMessages = messages.filter { !knownMessageIDs.contains($0.id) }
        for message in newMessages {
            knownMessageIDs.insert(message.id)
        }

        guard turnActive else { return }
        let newAssistant = newMessages.filter { $0.role == .assistant }
        pendingAssistantMessages.append(contentsOf: newAssistant)
    }

    private func waitForCommittedMessagesIfNeeded() async {
        guard pendingAssistantMessages.isEmpty else { return }
        let deadline = ContinuousClock.now + .milliseconds(configuration.commitWaitTimeoutMs)
        while pendingAssistantMessages.isEmpty {
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finalizeTurn(
        wasBounded: Bool,
        consumer: any ConversationStreamConsumer
    ) async {
        await waitForCommittedMessagesIfNeeded()

        if !pendingAssistantMessages.isEmpty {
            var payload = ConversationStreamPayloadAssembly.streamingFinalPayload(from: pendingAssistantMessages)
            if wasBounded, !configuration.boundedTurnNotice.isEmpty {
                if payload.text.isEmpty {
                    payload.text = configuration.boundedTurnNotice
                } else {
                    payload.text += "\n\n" + configuration.boundedTurnNotice
                }
            }
            let messageIDs = pendingAssistantMessages.map(\.id)
            if let prepared = mediaLedger.prepareFinal(committedMessageIDs: messageIDs, payload: payload) {
                await consumer.finishTurn(final: prepared)
            }
        } else if wasBounded, !configuration.boundedTurnNotice.isEmpty {
            await consumer.finishTurn(final: StreamingFinalPayload(text: configuration.boundedTurnNotice))
        }

        resetTurnState()
    }

    private func resetTurnState() {
        turnActive = false
        currentRunID = nil
        pendingAssistantMessages = []
        mediaLedger.reset()
    }
}
