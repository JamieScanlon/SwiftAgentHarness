import Foundation
import Logging
import SwiftAgentKit

/// Shared capability-aware resolution of ``ToolInvocationPolicy`` for provider adapters.
///
/// Adapters call ``effectivePolicy(config:features:hasTools:model:logger:)`` to clamp a
/// requested policy to what the model advertises via ``ModelRequestFeatures/toolChoiceModes``,
/// then translate the returned policy into their provider-specific wire field. Forcing is only
/// meaningful when tools are present, so an empty tool set always resolves to ``ToolInvocationPolicy/automatic``.
enum ToolChoiceTranslation {
    static func effectivePolicy(
        config: LLMRequestConfig,
        features: ModelRequestFeatures,
        hasTools: Bool,
        model: String,
        logger: Logger?
    ) -> ToolInvocationPolicy {
        guard hasTools else { return .automatic }
        let requested = config.toolInvocationPolicy
        let (effective, clamped) = features.resolve(requested)
        if clamped {
            logger?.warning(
                "[ToolChoice] clamped unsupported tool-choice policy model=\(model) requested=\(requested) effective=\(effective) supported=\(features.toolChoiceModes.map(\.rawValue).sorted())"
            )
        }
        return effective
    }
}
