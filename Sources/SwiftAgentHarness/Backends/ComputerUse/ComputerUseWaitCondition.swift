import Foundation

/// What `wait-for` waits on, evaluated against fresh snapshots of the target. Never natural language: no driver
/// can evaluate that.
public enum WaitCondition: Sendable, Codable, Hashable {
    public enum Presence: String, Sendable, Codable, Hashable {
        case appears
        case disappears
    }

    public enum Match: String, Sendable, Codable, Hashable {
        case equals
        case contains
    }

    /// An element matching every given field: role, accessible name (contained, ignoring case), or an element
    /// cited by ref from the latest observation.
    case element(Presence, role: String? = nil, name: String? = nil, ref: String? = nil)
    /// The page URL matches `pattern`, where `*` matches anything; a pattern without `*` matches as a substring.
    /// Browser targets.
    case url(pattern: String)
    /// A window of `app` (a bundle id), or the one window `windowID` names, in the target's window list. Titles
    /// are screen content an attacker controls, so no condition matches on them.
    case window(Presence, app: String, windowID: String? = nil)
    /// The value of the element cited by `ref` in the latest observation.
    case value(Match, ref: String, text: String)
    /// No visual or tree change for `quietMs`.
    case screenSettles(quietMs: Int)

    var summary: String {
        switch self {
        case .element(let presence, let role, let name, let ref):
            let what = [role, name.map { "\"\($0)\"" }, ref].compactMap { $0 }.joined(separator: " ")
            return "element \(what.isEmpty ? "any" : what) \(presence.rawValue)"
        case .url(let pattern): return "url matches \(pattern)"
        case .window(let presence, let app, let windowID):
            return "window \([app, windowID].compactMap { $0 }.joined(separator: " ")) \(presence.rawValue)"
        case .value(let match, let ref, let text): return "\(ref) value \(match.rawValue) \"\(text)\""
        case .screenSettles(let quietMs): return "screen settles for \(quietMs) ms"
        }
    }
}

/// Polls fresh observations until a condition holds or the timeout passes.
enum ComputerUseWaitEvaluator {
    enum Result: Sendable {
        case met(DisplayObservation, afterMilliseconds: Int)
        case timedOut(DisplayObservation?)
        /// The target can't show what the condition needs, such as a page URL.
        case unevaluable(String)
    }

    static let pollInterval: Duration = .milliseconds(250)

    /// The observation modes the condition needs on this target, or why it can't be evaluated there.
    static func modes(for condition: WaitCondition, manifest: DisplayTargetManifest) -> Result? {
        switch condition {
        case .element, .value:
            return manifest.perception.contains(.dom) || manifest.perception.contains(.accessibility)
                ? nil : .unevaluable("\(manifest.label) has no element tree")
        case .url:
            return manifest.perception.contains(.dom) ? nil : .unevaluable("\(manifest.label) shows no page URL")
        case .window, .screenSettles:
            return nil
        }
    }

    /// Polls the target's window list until a window condition holds. A target that lists no windows can't
    /// evaluate one.
    static func waitForWindow(
        _ condition: WaitCondition,
        timeoutMilliseconds: Int,
        describe: @Sendable () async throws -> TargetLayout
    ) async throws -> (met: Bool, afterMilliseconds: Int)? {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(timeoutMilliseconds))
        while true {
            guard let windows = try await describe().windows else { return nil }
            let now = clock.now
            if holds(condition, in: windows) { return (true, Int((now - start) / .milliseconds(1))) }
            guard now < deadline else { return (false, timeoutMilliseconds) }
            try await Task.sleep(for: pollInterval)
        }
    }

    static func holds(_ condition: WaitCondition, in windows: [WindowInfo]) -> Bool {
        guard case .window(let presence, let app, let windowID) = condition else { return false }
        let found = windows.contains { window in
            window.app.bundleID.caseInsensitiveCompare(app) == .orderedSame && (windowID == nil || window.ref.windowID == windowID)
        }
        return presence == .appears ? found : !found
    }

    static func observeRequest(for condition: WaitCondition, manifest: DisplayTargetManifest) -> ObserveRequest {
        let tree: ObservationMode = manifest.perception.contains(.dom) ? .dom : .accessibility
        switch condition {
        case .screenSettles, .window:
            var modes: [ObservationMode] = [.pixels]
            if manifest.perception.contains(tree) { modes.append(tree) }
            return ObserveRequest(modes: modes, scope: .display(nil))
        default:
            return ObserveRequest(modes: [tree], scope: .display(nil))
        }
    }

    /// `reference` resolves a ref condition to the element it names in the latest observation.
    static func wait(
        for condition: WaitCondition,
        timeoutMilliseconds: Int,
        reference: ElementRef?,
        observe: @Sendable () async throws -> DisplayObservation
    ) async throws -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .milliseconds(timeoutMilliseconds))
        var latest: DisplayObservation?
        var settled: (state: String, since: ContinuousClock.Instant)?
        while true {
            let observation = try await observe()
            latest = observation
            let now = clock.now
            let elapsed = Int((now - start) / .milliseconds(1))
            switch condition {
            case .screenSettles(let quietMs):
                let state = stateKey(observation)
                if let current = settled, current.state == state {
                    if now - current.since >= .milliseconds(quietMs) { return .met(observation, afterMilliseconds: elapsed) }
                } else {
                    settled = (state, now)
                }
            default:
                if holds(condition, in: observation, reference: reference) { return .met(observation, afterMilliseconds: elapsed) }
            }
            guard now < deadline else { return .timedOut(latest) }
            try await Task.sleep(for: pollInterval)
        }
    }

    static func holds(_ condition: WaitCondition, in observation: DisplayObservation, reference: ElementRef?) -> Bool {
        let elements = observation.tree.map { Array($0.elements.values) } ?? []
        switch condition {
        case .element(let presence, let role, let name, let ref):
            let found = elements.contains { element in
                if let role, element.role.lowercased() != role.lowercased(), !element.role.lowercased().hasSuffix(role.lowercased()) { return false }
                if let name, !(element.label ?? "").localizedCaseInsensitiveContains(name) { return false }
                if ref != nil {
                    guard let reference else { return false }
                    return element.role == reference.role && element.label == reference.label
                }
                return true
            }
            return presence == .appears ? found : !found
        case .url(let pattern):
            guard let url = observation.target.url else { return false }
            return matches(url, pattern: pattern)
        case .value(let match, _, let text):
            guard let reference,
                  let element = elements.first(where: { $0.role == reference.role && $0.label == reference.label }),
                  let value = element.value else { return false }
            return match == .equals ? value == text : value.localizedCaseInsensitiveContains(text)
        case .window, .screenSettles:
            return false
        }
    }

    static func matches(_ url: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return url.contains(pattern) }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(url)
        for (index, part) in parts.enumerated() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            if index == 0, range.lowerBound != rest.startIndex { return false }
            rest = rest[range.upperBound...]
        }
        return parts.last?.isEmpty == true || rest.isEmpty
    }

    private static func stateKey(_ observation: DisplayObservation) -> String {
        var hasher = Hasher()
        hasher.combine(observation.image?.data)
        // Trees name the observation they belong to, which changes on every poll.
        hasher.combine(observation.tree?.text.replacing(/obs=\S+/, with: ""))
        return String(hasher.finalize())
    }
}
