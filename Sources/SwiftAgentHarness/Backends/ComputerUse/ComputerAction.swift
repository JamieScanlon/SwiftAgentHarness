import Foundation

/// What a pointer or element action lands on. Both forms cite the observation they were planned against.
public enum ActionTarget: Sendable, Codable, Hashable {
    case ref(String, observation: ObservationID)
    /// Pixel fallback, already decoded to logical points in the target's global space.
    case point(DisplayPoint, observation: ObservationID)

    public var observation: ObservationID {
        switch self {
        case .ref(_, let observation), .point(_, let observation): return observation
        }
    }

    public var point: DisplayPoint? {
        if case .point(let point, _) = self { return point }
        return nil
    }

    public var elementRef: String? {
        if case .ref(let ref, _) = self { return ref }
        return nil
    }
}

public enum MouseButton: String, Sendable, Codable, Hashable {
    case left
    case right
    case middle
}

public enum PointerState: String, Sendable, Codable, Hashable {
    case down
    case up
}

public enum ScrollUnit: String, Sendable, Codable, Hashable {
    case line
    case pixel
}

public enum TypeMode: String, Sendable, Codable, Hashable {
    /// Synthesized key events.
    case keys
    /// Write the field directly and read it back.
    case setValue = "set-value"
    /// Save the clipboard, write, verify, paste, restore.
    case paste
}

public enum ComputerActionKind: String, Sendable, Codable, Hashable, CaseIterable {
    case click, move, drag, pointer, scroll, type, key, hold, press
    case setValue = "set-value"
    case menu, launch
    case openURL = "open-url"
    case wait
    case waitFor = "wait-for"
    case observe, zoom
}

/// The canonical action model every model dialect is decoded into.
public enum ComputerAction: Sendable, Codable, Hashable {
    case click(at: ActionTarget, button: MouseButton = .left, count: Int = 1, modifiers: [KeyModifier] = [])
    case move(to: ActionTarget)
    /// At least two targets; button down and up are guaranteed by the driver.
    case drag(path: [ActionTarget], modifiers: [KeyModifier] = [])
    case pointer(state: PointerState)
    case scroll(at: ActionTarget?, dx: Double, dy: Double, unit: ScrollUnit)
    /// `mode == nil` lets the driver pick.
    case type(text: String, into: ActionTarget? = nil, mode: TypeMode? = nil)
    case key(combo: KeyCombo, repeatCount: Int = 1)
    case hold(combo: KeyCombo, milliseconds: Int)
    case press(at: ActionTarget)
    case setValue(at: ActionTarget, value: String)
    case menu(path: [String], app: String? = nil)
    case launch(app: String, background: Bool = true)
    case openURL(String)
    case wait(milliseconds: Int)
    case waitFor(condition: String, timeoutMilliseconds: Int)
    case observe(ObserveRequest)
    /// A full-resolution crop; coordinates stay in the parent observation's space.
    case zoom(region: DisplayRect, observation: ObservationID)

    public var kind: ComputerActionKind {
        switch self {
        case .click: return .click
        case .move: return .move
        case .drag: return .drag
        case .pointer: return .pointer
        case .scroll: return .scroll
        case .type: return .type
        case .key: return .key
        case .hold: return .hold
        case .press: return .press
        case .setValue: return .setValue
        case .menu: return .menu
        case .launch: return .launch
        case .openURL: return .openURL
        case .wait: return .wait
        case .waitFor: return .waitFor
        case .observe: return .observe
        case .zoom: return .zoom
        }
    }

    public var citedTargets: [ActionTarget] {
        switch self {
        case .click(let at, _, _, _), .press(let at), .setValue(let at, _): return [at]
        case .move(let to): return [to]
        case .drag(let path, _): return path
        case .scroll(let at, _, _, _): return at.map { [$0] } ?? []
        case .type(_, let into, _): return into.map { [$0] } ?? []
        case .pointer, .key, .hold, .menu, .launch, .openURL, .wait, .waitFor, .observe, .zoom: return []
        }
    }

    /// Every observation this action depends on, including a zoom's parent.
    public var citedObservations: [ObservationID] {
        if case .zoom(_, let observation) = self { return [observation] }
        return citedTargets.map(\.observation)
    }
}

public struct ActionBatch: Sendable, Codable, Hashable {
    public var actions: [ComputerAction]

    public init(_ actions: [ComputerAction]) {
        self.actions = actions
    }
}

public enum ActionEffect: String, Sendable, Codable, Hashable {
    case confirmed
    case unverifiable
    case suspectedNoop = "suspected-noop"
    case partial
    case refused
    case notExecuted = "not-executed"

    /// Effects that stop the rest of a batch. `unverifiable` does not: most pixel clicks are unverifiable.
    public var stopsBatch: Bool {
        switch self {
        case .confirmed, .unverifiable: return false
        case .suspectedNoop, .partial, .refused, .notExecuted: return true
        }
    }

    /// An action that may already have been delivered. Never auto-retried; the next step is an observe.
    public var mayHaveBeenDelivered: Bool {
        switch self {
        case .confirmed, .unverifiable, .partial, .suspectedNoop: return true
        case .refused, .notExecuted: return false
        }
    }
}

public enum ActionEscalation: String, Sendable, Codable, Hashable {
    case observe
    case foreground
    case pixels
    case askUser = "ask-user"
}

public struct ActionOutcome: Sendable, Codable, Hashable {
    /// Index in the batch.
    public var action: Int
    public var effect: ActionEffect
    public var evidence: String?
    public var escalation: ActionEscalation?
    /// A fresh observation when the action produced one.
    public var observation: ObservationID?

    public init(
        action: Int,
        effect: ActionEffect,
        evidence: String? = nil,
        escalation: ActionEscalation? = nil,
        observation: ObservationID? = nil
    ) {
        self.action = action
        self.effect = effect
        self.evidence = evidence
        self.escalation = escalation
        self.observation = observation
    }
}
