import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("MediaDeliveryLedger")
struct MediaDeliveryLedgerTests {
    @Test("Suppresses exact duplicate final payload")
    func suppressExactDuplicate() {
        var ledger = MediaDeliveryLedger()
        ledger.recordBlock("Hello world")
        let result = ledger.prepareFinal(StreamingFinalPayload(text: "Hello world"))
        #expect(result == nil)
    }

    @Test("Strips duplicate media from final send")
    func stripDuplicateMedia() {
        var ledger = MediaDeliveryLedger()
        let ref = StreamingMediaRef(id: "blob-abc", kind: "image")
        ledger.recordMedia([ref])
        let result = ledger.prepareFinal(
            StreamingFinalPayload(text: "See attached", media: [ref])
        )
        #expect(result?.media.isEmpty == true)
        #expect(result?.text == "See attached")
    }

    @Test("Sends new text wrapping already-streamed media")
    func newTextWithStreamedMedia() {
        var ledger = MediaDeliveryLedger()
        let ref = StreamingMediaRef(id: "blob-abc", kind: "image")
        ledger.recordMedia([ref])
        let result = ledger.prepareFinal(
            StreamingFinalPayload(text: "Updated caption", media: [ref])
        )
        #expect(result?.text == "Updated caption")
        #expect(result?.media.isEmpty == true)
    }
}

@Suite("StreamingCancellation")
struct StreamingCancellationTests {
    @Test("Token delta keeps partial")
    func tokenDelta() {
        let actions = StreamingCancellation.resolve(
            granularity: .tokenDelta,
            partialText: "partial output",
            cancellationMarker: "cancelled"
        )
        #expect(actions.contains(.keepPartial(partialText: "partial output")))
    }

    @Test("Block appends cancellation marker")
    func block() {
        let actions = StreamingCancellation.resolve(
            granularity: .block,
            partialText: "ignored",
            cancellationMarker: "_(cancelled)_"
        )
        #expect(actions.contains(.appendCancellationMarker(marker: "_(cancelled)_")))
    }

    @Test("Preview resolves scratch message")
    func previewEdit() {
        let actions = StreamingCancellation.resolve(
            granularity: .previewEdit,
            partialText: "live preview",
            cancellationMarker: "x"
        )
        #expect(actions.contains(.resolvePreview(.cancelled(partialText: "live preview"))))
    }

    @Test("Final only emits notice")
    func finalOnly() {
        let actions = StreamingCancellation.resolve(
            granularity: .finalOnly,
            partialText: "",
            cancellationMarker: "stopped"
        )
        #expect(actions.contains(.emitNotice(CancellationNotice(marker: "stopped"))))
    }
}
