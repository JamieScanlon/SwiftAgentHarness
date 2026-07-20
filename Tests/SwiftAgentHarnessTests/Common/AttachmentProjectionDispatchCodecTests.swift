import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Attachment projection dispatch codec")
struct AttachmentProjectionDispatchCodecTests {
    @Test("LMStudio-style suffix is suppressed when materialized blocks are present")
    func suffixSuppressedWhenMaterialized() {
        let payload: JSON = .object([
            "contextEngineAttachmentProjection": .object([
                "projectionFingerprint": .string("fp"),
                "decisions": .array([
                    .object([
                        "attachmentName": .string("diagram.png"),
                        "disposition": .string("summarize"),
                    ]),
                ]),
                "materializedBlocks": .array([
                    .object([
                        "attachmentID": .string(UUID().uuidString),
                        "attachmentName": .string("diagram.png"),
                        "disposition": .string("summarize"),
                        "body": .string("[attachment digest]\npreview:\nhello"),
                    ]),
                ]),
            ]),
        ])
        #expect(AttachmentProjectionDispatchCodec.hasMaterializedBlocks(in: payload))
        let dispositions = AttachmentProjectionDispatchCodec.extractDispositions(from: payload)
        #expect(dispositions["diagram.png"] == "summarize")
    }
}
