import Foundation

public struct ClientSurfaceIntent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case openFileForEdit
        case execApprovalRequired
        case execApprovalCleared
        /// A computer-use specialist is waiting on the user: a question to answer or a step to take over.
        case computerUseRequest
        case computerUseRequestCleared
        /// What a computer-use specialist is doing: the "agent is using <target>" indicator.
        case computerUseActivity
    }

    public var v: Int
    public var kind: Kind
    /// Absolute path on the server host; valid only when the client surface is co-located (e.g. desktop app opening Application Support memory files).
    public var filePath: String
    public var scope: String?
    public var label: String?
    public var approvalID: String?
    public var command: String?
    /// Portable approval presentation a capable surface renders natively (and core
    /// degrades to text). Present on `execApprovalRequired` intents.
    public var presentation: ApprovalPresentation?
    /// Present on the `computerUse*` kinds.
    public var computerUse: ComputerUseSurfaceIntentPayload?

    public init(
        v: Int = 1,
        kind: Kind,
        filePath: String = "",
        scope: String? = nil,
        label: String? = nil,
        approvalID: String? = nil,
        command: String? = nil,
        presentation: ApprovalPresentation? = nil,
        computerUse: ComputerUseSurfaceIntentPayload? = nil
    ) {
        self.v = v
        self.kind = kind
        self.filePath = filePath
        self.scope = scope
        self.label = label
        self.approvalID = approvalID
        self.command = command
        self.presentation = presentation
        self.computerUse = computerUse
    }

    public static func computerUseRequest(_ payload: ComputerUseSurfaceIntentPayload) -> ClientSurfaceIntent {
        ClientSurfaceIntent(kind: .computerUseRequest, label: payload.prompt, computerUse: payload)
    }

    public static func computerUseRequestCleared(requestID: String, lifecycleID: String?) -> ClientSurfaceIntent {
        ClientSurfaceIntent(
            kind: .computerUseRequestCleared,
            computerUse: ComputerUseSurfaceIntentPayload(requestID: requestID, lifecycleID: lifecycleID)
        )
    }

    public static func computerUseActivity(_ payload: ComputerUseSurfaceIntentPayload) -> ClientSurfaceIntent {
        ClientSurfaceIntent(kind: .computerUseActivity, computerUse: payload)
    }
}

/// The computer-use part of a surface intent.
public struct ComputerUseSurfaceIntentPayload: Codable, Sendable, Equatable {
    public enum RequestKind: String, Codable, Sendable {
        /// Answer in text through `POST …/computer-use/requests/{id}`.
        case question
        /// Take over the screen, then hand control back.
        case handoff
    }

    public enum Status: String, Codable, Sendable {
        case started
        case acting
        case takenOver = "taken-over"
        case ended
    }

    public var requestID: String?
    public var requestKind: RequestKind?
    public var prompt: String?
    /// Why a handoff is needed: login, 2fa, captcha, payment, ambiguous, consequential.
    public var reason: String?
    /// The display target's label.
    public var target: String?
    /// The delegate call that started the specialist.
    public var lifecycleID: String?
    public var status: Status?
    public var step: Int?
    /// The current step allotment.
    public var maxSteps: Int?
    /// How many times the allotment was extended.
    public var extensions: Int?
    /// Bundle id or domain the latest action landed in.
    public var app: String?
    public var action: String?
    public var terminalReason: String?

    public init(
        requestID: String? = nil,
        requestKind: RequestKind? = nil,
        prompt: String? = nil,
        reason: String? = nil,
        target: String? = nil,
        lifecycleID: String? = nil,
        status: Status? = nil,
        step: Int? = nil,
        maxSteps: Int? = nil,
        extensions: Int? = nil,
        app: String? = nil,
        action: String? = nil,
        terminalReason: String? = nil
    ) {
        self.requestID = requestID
        self.requestKind = requestKind
        self.prompt = prompt
        self.reason = reason
        self.target = target
        self.lifecycleID = lifecycleID
        self.status = status
        self.step = step
        self.maxSteps = maxSteps
        self.extensions = extensions
        self.app = app
        self.action = action
        self.terminalReason = terminalReason
    }
}

extension ComputerUseSurfaceIntentPayload {
    /// "extended twice", or `nil` when the allotment was never extended.
    public var extensionsPhrase: String? {
        guard let extensions, extensions > 0 else { return nil }
        switch extensions {
        case 1: return "extended once"
        case 2: return "extended twice"
        default: return "extended \(extensions) times"
        }
    }
}
