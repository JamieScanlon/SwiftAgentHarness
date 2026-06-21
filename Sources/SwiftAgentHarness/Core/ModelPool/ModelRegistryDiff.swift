import Foundation

/// Pure utility that computes a stable ordered list of ``ModelRegistryChange`` entries between two
/// keyed ``Model`` snapshots. Used by ``ModelManager`` to emit granular `models/registry` events
/// (`added` / `removed` / `updated`) instead of full-snapshot fan-out on every change.
public enum ModelRegistryDiff {
    /// Computes deltas between `previous` and `next`, both keyed by canonical model UUID.
    ///
    /// Ordering is deterministic — sorted by UUID string per change kind, with `removed` first,
    /// then `updated`, then `added`. Equality between two ``Model`` values uses a JSON encoding
    /// with sorted keys so we don't require ``Model`` to conform to `Equatable`.
    ///
    public static func compute(
        previous: [UUID: Model],
        next: [UUID: Model]
    ) -> [ModelRegistryChange] {
        let prevIDs = Set(previous.keys)
        let nextIDs = Set(next.keys)

        let removedIDs = prevIDs.subtracting(nextIDs).sorted { $0.uuidString < $1.uuidString }
        let addedIDs = nextIDs.subtracting(prevIDs).sorted { $0.uuidString < $1.uuidString }
        let commonIDs = prevIDs.intersection(nextIDs).sorted { $0.uuidString < $1.uuidString }

        var changes: [ModelRegistryChange] = []
        changes.reserveCapacity(removedIDs.count + addedIDs.count + commonIDs.count)

        for id in removedIDs {
            changes.append(ModelRegistryChange(kind: .removed, modelID: id, previous: previous[id], current: nil))
        }
        for id in commonIDs {
            guard let p = previous[id], let n = next[id] else { continue }
            if !sameWireRepresentation(p, n) {
                changes.append(ModelRegistryChange(kind: .updated, modelID: id, previous: p, current: n))
            }
        }
        for id in addedIDs {
            changes.append(ModelRegistryChange(kind: .added, modelID: id, previous: nil, current: next[id]))
        }
        return changes
    }

    private static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func sameWireRepresentation(_ lhs: Model, _ rhs: Model) -> Bool {
        guard let l = try? stableEncoder.encode(lhs),
              let r = try? stableEncoder.encode(rhs)
        else { return false }
        return l == r
    }
}
