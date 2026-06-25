import Foundation

public struct ClientSurfaceIntent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case openFileForEdit
        case execApprovalRequired
        case execApprovalCleared
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

    public init(
        v: Int = 1,
        kind: Kind,
        filePath: String = "",
        scope: String? = nil,
        label: String? = nil,
        approvalID: String? = nil,
        command: String? = nil,
        presentation: ApprovalPresentation? = nil
    ) {
        self.v = v
        self.kind = kind
        self.filePath = filePath
        self.scope = scope
        self.label = label
        self.approvalID = approvalID
        self.command = command
        self.presentation = presentation
    }
}
