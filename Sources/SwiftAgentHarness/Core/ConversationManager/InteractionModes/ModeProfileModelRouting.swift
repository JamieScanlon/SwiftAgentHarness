import Foundation

/// Composes harness **`routing.modelQuery`**-shaped prefs with ``ResolvedModeProfile/model`` (`modes.md` model slice).
///
/// **Precedence:** persisted ``ConversationRoutingPrefs/queryJSON`` wins; then mode profile ``query``;
/// then the client-supplied ranking hint from ``ModelQuery`` (`preferredUseClass` / `preferredFamily`).
///
/// **Note:** Only ``ModelReference/query`` references are adjusted; wire callers typically use `.slug` / `.id`.
enum ModeProfileModelRouting {
    enum DispatchPrimaryQuerySource: Sendable, Equatable {
        case none
        case routingOverride
        case modeQuery
    }

    struct DispatchQueryWaterfall: Sendable, Equatable {
        let primarySource: DispatchPrimaryQuerySource
        let primaryQuery: String?
        /// Populated only when mode query is the primary source.
        let modeFallbackQuery: String?
    }

    static func effectiveRankingQuery(
        clientQuery: String?,
        routingQueryJSON: String?,
        resolvedProfile: ResolvedModeProfile
    ) -> String? {
        if let routing = routingQueryJSON?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return routing
        }
        if let modeQ = resolvedProfile.model.query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return modeQ
        }
        return clientQuery?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func effectiveModelReference(
        _ ref: ModelReference,
        routingQueryJSON: String?,
        resolvedProfile: ResolvedModeProfile
    ) -> ModelReference {
        switch ref {
        case .id, .slug:
            return ref
        case .query(let mq):
            let hintPieces = [mq.preferredUseClass, mq.preferredFamily].compactMap {
                $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            let clientHint = hintPieces.first
            guard let composed = effectiveRankingQuery(
                clientQuery: clientHint,
                routingQueryJSON: routingQueryJSON,
                resolvedProfile: resolvedProfile
            )?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return ref
            }
            var adjusted = mq
            adjusted.preferredUseClass = composed
            return .query(adjusted)
        }
    }

    /// Dispatch-time query waterfall:
    /// 1) conversation routing query (strict, no mode fallback cascade)
    /// 2) mode query
    /// 3) mode fallback (only if mode query exists and resolves empty)
    static func dispatchQueryWaterfall(
        routingQueryJSON: String?,
        resolvedProfile: ResolvedModeProfile
    ) -> DispatchQueryWaterfall {
        if let routing = routingQueryJSON?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return DispatchQueryWaterfall(
                primarySource: .routingOverride,
                primaryQuery: routing,
                modeFallbackQuery: nil
            )
        }
        guard let modeQuery = resolvedProfile.model.query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return DispatchQueryWaterfall(
                primarySource: .none,
                primaryQuery: nil,
                modeFallbackQuery: nil
            )
        }
        return DispatchQueryWaterfall(
            primarySource: .modeQuery,
            primaryQuery: modeQuery,
            modeFallbackQuery: resolvedProfile.model.fallback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
