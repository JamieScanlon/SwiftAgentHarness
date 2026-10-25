import Foundation

public typealias DisplayTargetID = String

public enum DisplayTargetIsolation: String, Sendable, Codable, Hashable {
    case host
    case vm
    case container
    case remoteBrowser = "remote-browser"
    case remoteDevice = "remote-device"
}

public enum ObservationMode: String, Sendable, Codable, Hashable {
    case pixels
    case accessibility
    case dom
    case ocr
}

public enum DisplayDeliveryMode: String, Sendable, Codable, Hashable {
    /// Element actions or process-routed events that do not take the user's focus or cursor.
    case background
    case foreground
}

public enum DisplaySemanticAction: String, Sendable, Codable, Hashable {
    case press
    case setValue = "set-value"
    case focus
    case menuPath = "menu-path"
    case launchApp = "launch-app"
    case openURL = "open-url"
    case runShortcut = "run-shortcut"
}

public enum DisplayObserverAccess: String, Sendable, Codable, Hashable {
    case vnc
    case stream
    case none
}

/// Platform permissions a target needs before it can observe or act.
public enum DisplayPlatformPermission: String, Sendable, Codable, Hashable {
    case screenCapture = "screen-capture"
    case accessibility
    case postEvents = "post-events"
    case inputMonitoring = "input-monitoring"
    case automation
}

public enum DisplayHumanPresence: String, Sendable, Codable, Hashable {
    /// A person may be using this screen right now.
    case shared
    /// Nobody uses this screen but the agent (VMs, containers, managed browsers).
    case none
}

/// What a display-target plugin declares. Grants, delivery defaults, and confirmation requirements are derived from
/// `isolation` and `humanPresence`, so a VM and the user's own desktop never share a permission profile by accident.
public struct DisplayTargetManifest: Sendable, Codable, Hashable {
    public static let kind = "display-target"

    public var id: DisplayTargetID
    public var label: String
    public var platform: String
    public var isolation: DisplayTargetIsolation
    public var perception: [ObservationMode]
    public var delivery: [DisplayDeliveryMode]
    public var semanticActions: [DisplaySemanticAction]
    public var multiDisplay: Bool
    public var observerAccess: DisplayObserverAccess
    public var requires: [DisplayPlatformPermission]
    public var humanPresence: DisplayHumanPresence

    public init(
        id: DisplayTargetID,
        label: String,
        platform: String,
        isolation: DisplayTargetIsolation,
        perception: [ObservationMode],
        delivery: [DisplayDeliveryMode],
        semanticActions: [DisplaySemanticAction] = [],
        multiDisplay: Bool = false,
        observerAccess: DisplayObserverAccess = .none,
        requires: [DisplayPlatformPermission] = [],
        humanPresence: DisplayHumanPresence
    ) {
        self.id = id
        self.label = label
        self.platform = platform
        self.isolation = isolation
        self.perception = perception
        self.delivery = delivery
        self.semanticActions = semanticActions
        self.multiDisplay = multiDisplay
        self.observerAccess = observerAccess
        self.requires = requires
        self.humanPresence = humanPresence
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, kind, platform, isolation, perception, delivery, semanticActions, multiDisplay
        case observerAccess, requires, humanPresence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == Self.kind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "expected kind \"\(Self.kind)\", found \"\(kind)\""
            )
        }
        self.init(
            id: try container.decode(DisplayTargetID.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            platform: try container.decode(String.self, forKey: .platform),
            isolation: try container.decode(DisplayTargetIsolation.self, forKey: .isolation),
            perception: try container.decode([ObservationMode].self, forKey: .perception),
            delivery: try container.decode([DisplayDeliveryMode].self, forKey: .delivery),
            semanticActions: try container.decodeIfPresent([DisplaySemanticAction].self, forKey: .semanticActions) ?? [],
            multiDisplay: try container.decodeIfPresent(Bool.self, forKey: .multiDisplay) ?? false,
            observerAccess: try container.decodeIfPresent(DisplayObserverAccess.self, forKey: .observerAccess) ?? .none,
            requires: try container.decodeIfPresent([DisplayPlatformPermission].self, forKey: .requires) ?? [],
            humanPresence: try container.decode(DisplayHumanPresence.self, forKey: .humanPresence)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(platform, forKey: .platform)
        try container.encode(isolation, forKey: .isolation)
        try container.encode(perception, forKey: .perception)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(semanticActions, forKey: .semanticActions)
        try container.encode(multiDisplay, forKey: .multiDisplay)
        try container.encode(observerAccess, forKey: .observerAccess)
        try container.encode(requires, forKey: .requires)
        try container.encode(humanPresence, forKey: .humanPresence)
    }
}
