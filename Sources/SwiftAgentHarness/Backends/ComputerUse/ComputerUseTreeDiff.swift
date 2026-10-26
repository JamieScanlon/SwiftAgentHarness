import Foundation

/// Session-stable element refs.
///
/// Drivers number refs per traversal, so one inserted element renumbers everything after it. Each new tree is
/// matched against the previous one by role, subrole, and label, with frames breaking ties. A matched element
/// keeps its ref. An unmatched one keeps the driver's ref if no element has used it before, and otherwise gets
/// a fresh one. The model only ever sees these public refs; actions are translated back before they reach the
/// target.
struct ComputerUseRefStabilizer: Sendable {
    /// Same-looking elements farther apart than this are different elements.
    static let duplicateMatchDistance = 100.0

    private var issued: Set<String> = []
    private var counter = 0
    private var previous: ObservationTree?
    /// Public ref → driver ref, per observation.
    private var driverRefs: [ObservationID: [String: String]] = [:]

    private struct Key: Hashable {
        var role: String
        var subrole: String?
        var label: String?
    }

    func driverRef(_ publicRef: String, observation: ObservationID) -> String? {
        driverRefs[observation]?[publicRef]
    }

    mutating func forget(_ observation: ObservationID) {
        driverRefs.removeValue(forKey: observation)
    }

    /// `observation` with its tree rewritten to public refs. Observations without a tree pass through.
    mutating func stabilize(_ observation: DisplayObservation) -> DisplayObservation {
        guard let tree = observation.tree else { return observation }
        let order = Self.refOrder(in: tree)
        var mapping: [String: String] = [:]

        if let previous {
            var unclaimed: [Key: [ElementRef]] = [:]
            for ref in Self.refOrder(in: previous) {
                guard let element = previous.elements[ref] else { continue }
                unclaimed[Self.key(element), default: []].append(element)
            }
            var arrivals: [Key: [String]] = [:]
            for ref in order {
                guard let element = tree.elements[ref] else { continue }
                arrivals[Self.key(element), default: []].append(ref)
            }
            for (key, newRefs) in arrivals {
                let priors = unclaimed[key] ?? []
                if newRefs.count == 1, priors.count == 1 {
                    mapping[newRefs[0]] = priors[0].id
                    continue
                }
                // Greedy by distance, so each element claims its nearest same-looking predecessor.
                var pairs: [(new: String, prior: String, distance: Double)] = []
                for new in newRefs {
                    for prior in priors {
                        let distance = Self.distance(tree.elements[new]?.frame, prior.frame)
                        if distance <= Self.duplicateMatchDistance { pairs.append((new, prior.id, distance)) }
                    }
                }
                var claimedNew: Set<String> = []
                var claimedPrior: Set<String> = []
                for pair in pairs.sorted(by: { $0.distance < $1.distance })
                where !claimedNew.contains(pair.new) && !claimedPrior.contains(pair.prior) {
                    mapping[pair.new] = pair.prior
                    claimedNew.insert(pair.new)
                    claimedPrior.insert(pair.prior)
                }
            }
        }

        for ref in order where mapping[ref] == nil {
            let taken = Set(mapping.values)
            mapping[ref] = !issued.contains(ref) && !taken.contains(ref) ? ref : nextFreshRef(avoiding: taken)
        }
        issued.formUnion(mapping.values)
        for ref in mapping.values { counter = max(counter, Self.number(ref) ?? 0) }

        var stable = tree
        stable.text = Self.replacingRefs(in: tree.text, mapping: mapping)
        stable.elements = Dictionary(uniqueKeysWithValues: tree.elements.compactMap { driverRef, element in
            guard let publicRef = mapping[driverRef] else { return nil }
            var renamed = element
            renamed.id = publicRef
            return (publicRef, renamed)
        })
        driverRefs[observation.id] = Dictionary(uniqueKeysWithValues: mapping.map { ($0.value, $0.key) })
        previous = stable

        var result = observation
        result.tree = stable
        return result
    }

    private mutating func nextFreshRef(avoiding taken: Set<String>) -> String {
        repeat {
            counter += 1
        } while issued.contains("e\(counter)") || taken.contains("e\(counter)")
        return "e\(counter)"
    }

    /// Refs in the order the text shows them, then any the text doesn't show.
    static func refOrder(in tree: ObservationTree) -> [String] {
        var seen: Set<String> = []
        var order: [String] = []
        for token in refTokens(in: tree.text) where tree.elements[token] != nil && seen.insert(token).inserted {
            order.append(token)
        }
        for ref in tree.elements.keys.sorted() where seen.insert(ref).inserted {
            order.append(ref)
        }
        return order
    }

    static func refTokens(in text: String) -> [String] {
        text.matches(of: /\[([^\]\s]+)\]/).map { String($0.output.1) }
    }

    private static func replacingRefs(in text: String, mapping: [String: String]) -> String {
        text.replacing(/\[([^\]\s]+)\]/) { match in
            let ref = String(match.output.1)
            return "[\(mapping[ref] ?? ref)]"
        }
    }

    private static func key(_ element: ElementRef) -> Key {
        Key(role: element.role, subrole: element.subrole, label: element.label)
    }

    private static func distance(_ a: DisplayRect?, _ b: DisplayRect?) -> Double {
        guard let a, let b else { return .infinity }
        let dx = a.center.x - b.center.x
        let dy = a.center.y - b.center.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func number(_ ref: String) -> Int? {
        guard ref.first == "e" else { return nil }
        return Int(ref.dropFirst())
    }
}

/// What changed in a tree since an earlier observation, both on session-stable refs.
public struct ObservationTreeDiff: Sendable, Codable, Hashable {
    public var base: ObservationID
    /// Compact text for the model, in place of the full tree.
    public var text: String
}

enum ComputerUseTreeDiff {
    /// The current tree's header, then added (`+`), changed (`~`), and removed (`-`) elements. Unchanged elements
    /// are only counted: they keep their refs and can be cited with the new observation.
    static func render(base: ObservationTree, baseID: ObservationID, current: ObservationTree) -> String {
        let baseLines = linesByRef(base)
        let currentLines = linesByRef(current)
        var added: [String] = []
        var changed: [String] = []
        var unchanged = 0
        for ref in ComputerUseRefStabilizer.refOrder(in: current) {
            guard let line = currentLines[ref] else { continue }
            if let before = baseLines[ref] {
                if normalized(before) == normalized(line) { unchanged += 1 } else { changed.append("~ " + normalized(line)) }
            } else {
                added.append("+ " + normalized(line))
            }
        }
        let removed = ComputerUseRefStabilizer.refOrder(in: base)
            .filter { currentLines[$0] == nil }
            .compactMap { baseLines[$0].map { "- " + normalized($0) } }

        var lines: [String] = []
        if let header = current.text.split(separator: "\n", omittingEmptySubsequences: false).first,
           ComputerUseRefStabilizer.refTokens(in: String(header)).isEmpty {
            lines.append(String(header))
        }
        if added.isEmpty, changed.isEmpty, removed.isEmpty {
            lines.append("No changes since \(baseID); its \(unchanged) elements keep their refs and can be cited with this observation.")
        } else {
            lines.append(
                "Changes since \(baseID): \(added.count) added, \(changed.count) changed, \(removed.count) removed, "
                    + "\(unchanged) unchanged. Unchanged elements keep their refs and can be cited with this observation."
            )
            lines += added + changed + removed
        }
        return lines.joined(separator: "\n")
    }

    /// The full tree, explaining why there is no diff.
    static func unavailable(baseID: ObservationID, current: ObservationTree) -> String {
        "\(baseID) is no longer retained, so the full tree follows.\n" + current.text
    }

    /// Each element's own line; a line's first ref token names it.
    private static func linesByRef(_ tree: ObservationTree) -> [String: String] {
        var lines: [String: String] = [:]
        for line in tree.text.split(separator: "\n") {
            guard let ref = ComputerUseRefStabilizer.refTokens(in: String(line)).first, lines[ref] == nil else { continue }
            lines[ref] = String(line)
        }
        return lines
    }

    private static func normalized(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}

extension ActionTarget {
    func mappingElementRef(_ transform: (String, ObservationID) -> String) -> ActionTarget {
        guard case .ref(let ref, let observation) = self else { return self }
        return .ref(transform(ref, observation), observation: observation)
    }
}

extension ComputerAction {
    /// This action with every element ref passed through `transform`, such as from public to driver refs.
    func mappingElementRefs(_ transform: (String, ObservationID) -> String) -> ComputerAction {
        switch self {
        case .click(let at, let button, let count, let modifiers):
            return .click(at: at.mappingElementRef(transform), button: button, count: count, modifiers: modifiers)
        case .move(let to):
            return .move(to: to.mappingElementRef(transform))
        case .drag(let path, let modifiers):
            return .drag(path: path.map { $0.mappingElementRef(transform) }, modifiers: modifiers)
        case .scroll(let at, let dx, let dy, let unit):
            return .scroll(at: at?.mappingElementRef(transform), dx: dx, dy: dy, unit: unit)
        case .type(let text, let into, let mode):
            return .type(text: text, into: into?.mappingElementRef(transform), mode: mode)
        case .press(let at):
            return .press(at: at.mappingElementRef(transform))
        case .setValue(let at, let value):
            return .setValue(at: at.mappingElementRef(transform), value: value)
        case .pointer, .key, .hold, .menu, .launch, .openURL, .wait, .waitFor, .observe, .zoom:
            return self
        }
    }
}
