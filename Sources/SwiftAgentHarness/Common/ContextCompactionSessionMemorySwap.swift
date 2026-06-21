import Foundation
import SwiftAgentKit

enum ContextCompactionSessionMemorySwap: Sendable {
    static func memoryNoteMessage(note: String) -> Message {
        Message(
            id: UUID(),
            role: .system,
            content: note,
            timestamp: Date(),
            toolCalls: []
        )
    }

    static func swappedMiddle(note: String, middle: [Message], tail: [Message]) -> [Message] {
        let tailIDs = Set(tail.map(\.id))
        let overlap = middle.filter { tailIDs.contains($0.id) }
        return [memoryNoteMessage(note: note)] + overlap
    }
}
