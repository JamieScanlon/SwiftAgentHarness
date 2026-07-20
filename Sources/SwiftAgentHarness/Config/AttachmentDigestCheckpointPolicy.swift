import Foundation

/// Fingerprint for persisted attachment digest checkpoints (bump when digest rules change materially).
enum AttachmentDigestCheckpointPolicy {
    static func configFingerprint(
        configuration: AttachmentRepresentationMaterializerConfiguration,
        modelSupportsVision: Bool
    ) -> String {
        [
            "attachment_digest_v1",
            String(configuration.digestHeadMaxBytes),
            String(configuration.digestTailMaxBytes),
            modelSupportsVision ? "1" : "0",
        ].joined(separator: "|")
    }
}
