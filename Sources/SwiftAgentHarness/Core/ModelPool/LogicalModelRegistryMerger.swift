import Foundation
import Logging

/// Groups single-binding discovery rows into multi-binding logical model entries.
enum LogicalModelRegistryMerger {
    struct DerivedJoin: Sendable, Equatable {
        var providerId: String
        var endpointModelId: String
        var matchedKey: String
    }

    static func merge(
        entries: [ModelRegistryEntry],
        providerPreference: ModelPoolProviderPreferenceConfiguration,
        logger: Logger? = nil
    ) -> [UUID: ModelRegistryEntry] {
        let explicitKeys = Set(entries.compactMap(\.canonicalModelKey))
        var derivedJoins: [DerivedJoin] = []
        var resolvedKeys: [UUID: String] = [:]
        var passthrough: [UUID: ModelRegistryEntry] = [:]

        for entry in entries {
            if let key = entry.canonicalModelKey {
                resolvedKeys[entry.id] = key
                continue
            }
            guard let binding = entry.primaryBinding else {
                passthrough[entry.id] = entry
                continue
            }
            if let derived = LogicalModelKey.deriveCanonicalKey(
                providerId: binding.providerId,
                endpointModelId: binding.endpointModelId,
                explicitKeys: explicitKeys
            ) {
                resolvedKeys[entry.id] = derived
                derivedJoins.append(
                    DerivedJoin(
                        providerId: binding.providerId,
                        endpointModelId: binding.endpointModelId,
                        matchedKey: derived
                    )
                )
            } else {
                passthrough[entry.id] = entry
            }
        }

        for join in derivedJoins {
            logger?.info(
                "Derived canonicalModelKey join: provider=\(join.providerId) endpoint=\(join.endpointModelId) matchedKey=\(join.matchedKey)"
            )
        }

        var groups: [String: [ModelRegistryEntry]] = [:]
        for entry in entries {
            guard let key = resolvedKeys[entry.id] else { continue }
            groups[key, default: []].append(entry)
        }

        var merged: [UUID: ModelRegistryEntry] = passthrough
        for (key, group) in groups {
            if group.count == 1, let single = group.first {
                merged[single.id] = single
                continue
            }
            if let combined = mergeGroup(
                key: key,
                entries: group,
                providerPreference: providerPreference
            ) {
                merged[combined.id] = combined
            }
        }
        return merged
    }

    private static func mergeGroup(
        key: String,
        entries: [ModelRegistryEntry],
        providerPreference: ModelPoolProviderPreferenceConfiguration
    ) -> ModelRegistryEntry? {
        let sortedSources = entries.sorted { lhs, rhs in
            let lhsRank = sourceRank(lhs, providerPreference: providerPreference)
            let rhsRank = sourceRank(rhs, providerPreference: providerPreference)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard let authoritative = sortedSources.first else { return nil }

        var bindings: [ProviderBinding] = []
        for source in sortedSources {
            guard let binding = source.primaryBinding else { continue }
            let preferenceIndex = providerPreference.preferenceIndex(for: binding.providerId)
            let catalogOffset = binding.priority
            var mergedBinding = binding
            mergedBinding.priority = preferenceIndex * 10 + catalogOffset
            if mergedBinding.cost == nil {
                mergedBinding.cost = source.cost
            }
            if mergedBinding.routing == nil {
                mergedBinding.routing = source.routing
            }
            bindings.append(mergedBinding)
        }
        bindings = dedupeBindings(bindings)

        let family = authoritative.family
            ?? authoritative.canonicalModelKey.flatMap(LogicalModelKey.inferredFamily(from:))
            ?? LogicalModelKey.inferredFamily(from: key)

        return ModelRegistryEntry(
            id: authoritative.id,
            family: family,
            displayName: authoritative.displayName,
            capabilities: authoritative.capabilities,
            requestFeatures: authoritative.requestFeatures,
            maxContextLength: coalesceOptional(sortedSources.map(\.maxContextLength)),
            maxOutputTokens: coalesceOptional(sortedSources.map(\.maxOutputTokens)),
            providers: bindings,
            useClasses: authoritative.useClasses,
            cost: authoritative.cost ?? bindings.first?.cost,
            performance: coalesceOptional(sortedSources.map(\.performance)),
            routing: authoritative.routing ?? bindings.first?.routing,
            compat: authoritative.compat ?? coalesceOptional(sortedSources.map(\.compat)),
            canonicalModelKey: key
        )
    }

    private static func sourceRank(
        _ entry: ModelRegistryEntry,
        providerPreference: ModelPoolProviderPreferenceConfiguration
    ) -> Int {
        guard let providerId = entry.primaryBinding?.providerId else { return Int.max }
        return providerPreference.preferenceIndex(for: providerId)
    }

    private static func dedupeBindings(_ bindings: [ProviderBinding]) -> [ProviderBinding] {
        var bestByKey: [BindingKey: ProviderBinding] = [:]
        for binding in bindings {
            let key = BindingKey(
                providerId: binding.providerId,
                endpointModelId: binding.endpointModelId,
                serverURL: binding.serverURL.absoluteString
            )
            if let existing = bestByKey[key] {
                if binding.priority < existing.priority {
                    bestByKey[key] = binding
                }
            } else {
                bestByKey[key] = binding
            }
        }
        return bestByKey.values.sorted { $0.priority < $1.priority }
    }

    private static func coalesceOptional<T>(_ values: [T?]) -> T? {
        values.compactMap { $0 }.first
    }

    private struct BindingKey: Hashable {
        var providerId: String
        var endpointModelId: String
        var serverURL: String
    }
}
