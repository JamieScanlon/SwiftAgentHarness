import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment access index")
struct AttachmentAccessIndexTests {
    private func makeDescriptor(id: UUID = UUID(), name: String = "doc.txt") -> ConversationAttachmentDescriptor {
        ConversationAttachmentDescriptor(
            id: id,
            kind: "document",
            name: name,
            mimeType: "text/plain",
            byteSize: 128
        )
    }

    private func fillerMessages(count: Int) -> [Message] {
        (0..<count).map { index in
            Message(
                id: UUID(),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "turn-\(index)",
                timestamp: Date(),
                toolCalls: []
            )
        }
    }

    @Test("read_attachment tool calls update access records")
    func readAttachmentUpdatesAccess() {
        let attachmentID = UUID()
        let catalog = [makeDescriptor(id: attachmentID)]
        var messages = fillerMessages(count: 6)
        messages.append(
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [
                    ToolCall(
                        name: ConversationAttachmentToolProvider.readAttachmentToolName,
                        arguments: .object(["attachment_id": .string(attachmentID.uuidString)]),
                        id: "tc-1"
                    ),
                ]
            )
        )
        messages.append(contentsOf: fillerMessages(count: 2))

        let index = AttachmentAccessIndexBuilder.build(messages: messages, catalog: catalog)
        #expect(index.currentTurnIndex == messages.count)
        #expect(index.lastAccessTurnIndex(for: attachmentID) == 6)
        #expect(index.accessCount(for: attachmentID) == 1)
        #expect(index.turnsSinceAccess(for: attachmentID) == 3)
    }

    @Test("catalog entries without transcript access are attach-hot at current turn")
    func attachTimeHotDefaults() {
        let attachmentID = UUID()
        let catalog = [makeDescriptor(id: attachmentID)]
        let messages = fillerMessages(count: 4)

        let index = AttachmentAccessIndexBuilder.build(messages: messages, catalog: catalog)
        #expect(index.lastAccessTurnIndex(for: attachmentID) == messages.count)
        #expect(index.accessCount(for: attachmentID) == 0)
        #expect(index.turnsSinceAccess(for: attachmentID) == 0)
    }

    @Test("UUID mention scan records conservative access")
    func mentionScanRecordsAccess() {
        let attachmentID = UUID()
        let catalog = [makeDescriptor(id: attachmentID)]
        var messages = fillerMessages(count: 2)
        messages.append(
            Message(
                id: UUID(),
                role: .user,
                content: "please review \(attachmentID.uuidString.lowercased())",
                timestamp: Date(),
                toolCalls: []
            )
        )

        let index = AttachmentAccessIndexBuilder.build(messages: messages, catalog: catalog)
        #expect(index.lastAccessTurnIndex(for: attachmentID) == 2)
        #expect(index.accessCount(for: attachmentID) == 1)
    }
}
