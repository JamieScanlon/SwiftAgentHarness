#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftAgentHarness

/// Preflights and requests the TCC permissions one at a time. Implementations must call the system preflight
/// APIs on every query: blank captures, missing window names, and failed calls are not permission signals.
public protocol MacPermissionProbing: Sendable {
    func isGranted(_ permission: DisplayPlatformPermission) -> Bool
    /// Shows the system prompt where one exists. Returns the state afterwards.
    func request(_ permission: DisplayPlatformPermission) -> Bool
}

/// The system preflight and request APIs. TCC attributes them to the responsible process: run from a terminal,
/// the terminal's grants apply.
public struct LiveMacPermissionProbe: MacPermissionProbing {
    public init() {}

    public func isGranted(_ permission: DisplayPlatformPermission) -> Bool {
        switch permission {
        case .screenCapture: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .postEvents: return CGPreflightPostEventAccess()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .automation: return false
        }
    }

    public func request(_ permission: DisplayPlatformPermission) -> Bool {
        switch permission {
        case .screenCapture: return CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .postEvents: return CGRequestPostEventAccess()
        case .inputMonitoring: return CGRequestListenEventAccess()
        case .automation: return false
        }
    }
}

public struct MacPermissionChecklistItem: Sendable, Hashable {
    public var permission: DisplayPlatformPermission
    public var granted: Bool
    /// What the permission enables, for the onboarding screen.
    public var explanation: String
    public var settingsURL: URL?
    /// Screen Recording usually takes effect only for a new process.
    public var relaunchAfterGrant: Bool
}

/// Permission state for the macOS display target, plus the onboarding checklist a host shows.
public struct MacPermissionBroker: Sendable {
    public let probe: any MacPermissionProbing

    public init(probe: any MacPermissionProbing = LiveMacPermissionProbe()) {
        self.probe = probe
    }

    public func snapshot(_ required: [DisplayPlatformPermission]) -> PermissionSnapshot {
        PermissionSnapshot(states: Dictionary(uniqueKeysWithValues: required.map {
            ($0, probe.isGranted($0) ? PermissionState.granted : .denied)
        }))
    }

    /// Prompts for each missing permission. Returns the snapshot afterwards.
    @discardableResult
    public func requestMissing(_ required: [DisplayPlatformPermission]) -> PermissionSnapshot {
        for permission in required where !probe.isGranted(permission) {
            _ = probe.request(permission)
        }
        return snapshot(required)
    }

    public func checklist(_ required: [DisplayPlatformPermission]) -> [MacPermissionChecklistItem] {
        required.map { permission in
            MacPermissionChecklistItem(
                permission: permission,
                granted: probe.isGranted(permission),
                explanation: Self.explanation(permission),
                settingsURL: Self.settingsURL(permission),
                relaunchAfterGrant: permission == .screenCapture
            )
        }
    }

    static func explanation(_ permission: DisplayPlatformPermission) -> String {
        switch permission {
        case .screenCapture:
            return "Screen Recording lets the agent take screenshots of the apps you grant. macOS may ask you to reconfirm it from time to time; that prompt is expected."
        case .accessibility:
            return "Accessibility lets the agent read app controls and press buttons without moving your pointer."
        case .postEvents:
            return "Posting events lets the agent type and click in the apps you grant."
        case .inputMonitoring:
            return "Input Monitoring lets the stop key end the agent's session from any app."
        case .automation:
            return "Automation lets the agent script apps that support Apple Events."
        }
    }

    /// Deep links rather than pane names, which change between releases.
    static func settingsURL(_ permission: DisplayPlatformPermission) -> URL? {
        let anchor: String
        switch permission {
        case .screenCapture: anchor = "Privacy_ScreenCapture"
        case .accessibility, .postEvents: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}
#endif
