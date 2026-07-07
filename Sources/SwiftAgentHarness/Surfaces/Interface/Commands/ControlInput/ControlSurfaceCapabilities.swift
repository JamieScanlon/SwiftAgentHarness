import Foundation

public enum NativeRegistrationSupport: String, Sendable, Equatable, Codable, CaseIterable {
    case unsupported
    case platformManaged
    case appManaged
}

public enum CompletionStyle: String, Sendable, Equatable, Codable, CaseIterable {
    case none
    case terminalAutocomplete
    case platformPicker
}

/// Per-surface control-input capabilities. Text commands are always the floor.
public struct ControlSurfaceCapabilities: Sendable, Equatable, Hashable {
    /// Parsing `/...` from inbound messages; always enabled as the universal floor.
    public var textCommandsEnabled: Bool
    public var nativeRegistration: NativeRegistrationSupport
    public var completionStyle: CompletionStyle

    public init(
        textCommandsEnabled: Bool = true,
        nativeRegistration: NativeRegistrationSupport = .unsupported,
        completionStyle: CompletionStyle = .none
    ) {
        self.textCommandsEnabled = textCommandsEnabled
        self.nativeRegistration = nativeRegistration
        self.completionStyle = completionStyle
    }

    /// Native registration is additive; text parsing remains available.
    public var effectiveTextCommandsEnabled: Bool {
        textCommandsEnabled || nativeRegistration != .unsupported
    }

    public static let terminal = ControlSurfaceCapabilities(
        textCommandsEnabled: true,
        nativeRegistration: .unsupported,
        completionStyle: .terminalAutocomplete
    )

    public static let socialChannel = ControlSurfaceCapabilities(
        textCommandsEnabled: true,
        nativeRegistration: .platformManaged,
        completionStyle: .platformPicker
    )

    public static let operatorChannel = ControlSurfaceCapabilities(
        textCommandsEnabled: true,
        nativeRegistration: .appManaged,
        completionStyle: .terminalAutocomplete
    )

    public static let thinChannel = ControlSurfaceCapabilities(
        textCommandsEnabled: true,
        nativeRegistration: .unsupported,
        completionStyle: .none
    )
}
