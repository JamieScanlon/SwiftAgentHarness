import Foundation

public typealias ObservationID = String

/// An app as the harness identifies it: by bundle id and declared category, never by window title or display name,
/// which are attacker-controllable screen content.
public struct AppIdentity: Sendable, Codable, Hashable {
    public var bundleID: String
    /// Platform app category (for example `public.app-category.finance`).
    public var category: String?

    public init(bundleID: String, category: String? = nil) {
        self.bundleID = bundleID
        self.category = category
    }
}

/// A window pinned to its process generation. Process ids are recycled, so the start time is part of the identity.
public struct WindowRef: Sendable, Codable, Hashable {
    public var pid: Int32
    public var processStart: Date
    public var windowID: String
    public var bounds: DisplayRect

    public init(pid: Int32, processStart: Date, windowID: String, bounds: DisplayRect) {
        self.pid = pid
        self.processStart = processStart
        self.windowID = windowID
        self.bounds = bounds
    }
}

public enum ObservationScope: Sendable, Codable, Hashable {
    /// A whole display; `nil` means the target's primary display.
    case display(String?)
    case window(WindowRef)
    case tab(String)
    case region(DisplayRect)
}

public struct ObservationImageLimit: Sendable, Codable, Hashable {
    public var longEdgePx: Int
    public var maxVisualTokens: Int?
    /// Most pixels in one image. Vendors that reject large images instead of downscaling them cap the area as
    /// well as the edge.
    public var maxPixels: Int?

    public init(longEdgePx: Int, maxVisualTokens: Int? = nil, maxPixels: Int? = nil) {
        self.longEdgePx = longEdgePx
        self.maxVisualTokens = maxVisualTokens
        self.maxPixels = maxPixels
    }
}

public struct ObserveRequest: Sendable, Codable, Hashable {
    public var modes: [ObservationMode]
    public var scope: ObservationScope
    /// Taken from the bound model's limits, never a constant.
    public var maxImage: ObservationImageLimit?
    /// A prior observation to diff the tree against.
    public var diffAgainst: ObservationID?

    public init(
        modes: [ObservationMode],
        scope: ObservationScope,
        maxImage: ObservationImageLimit? = nil,
        diffAgainst: ObservationID? = nil
    ) {
        self.modes = modes
        self.scope = scope
        self.maxImage = maxImage
        self.diffAgainst = diffAgainst
    }
}

/// What an observation was taken of.
public struct ObservationTarget: Sendable, Codable, Hashable {
    public var app: AppIdentity?
    public var pid: Int32?
    public var processStart: Date?
    public var windowID: String?
    public var tabID: String?
    /// The page URL for browser targets.
    public var url: String?
    /// Where the page sits when an app's own controls surround it, as in a desktop browser. Points outside it land on
    /// the app, not the page.
    public var pageBounds: DisplayRect?
    public var bounds: DisplayRect

    public init(
        app: AppIdentity? = nil,
        pid: Int32? = nil,
        processStart: Date? = nil,
        windowID: String? = nil,
        tabID: String? = nil,
        url: String? = nil,
        pageBounds: DisplayRect? = nil,
        bounds: DisplayRect
    ) {
        self.app = app
        self.pid = pid
        self.processStart = processStart
        self.windowID = windowID
        self.tabID = tabID
        self.url = url
        self.pageBounds = pageBounds
        self.bounds = bounds
    }
}

public struct ObservationImage: Sendable, Codable, Hashable {
    public var blobRef: String
    /// The encoded image exactly as sized for the model (`geometry.imageSize`). Sent to the model as an image
    /// part; `nil` when the driver only stored it by reference.
    public var data: Data?
    public var mediaType: String
    public var geometry: ScreenshotGeometry
    public var capturedAt: Date

    public init(
        blobRef: String,
        data: Data? = nil,
        mediaType: String = "image/png",
        geometry: ScreenshotGeometry,
        capturedAt: Date
    ) {
        self.blobRef = blobRef
        self.data = data
        self.mediaType = mediaType
        self.geometry = geometry
        self.capturedAt = capturedAt
    }
}

/// One element of an accessibility or DOM tree as the harness sees it. Frames live here, not in the model's text.
public struct ElementRef: Sendable, Codable, Hashable {
    public var id: String
    /// Platform role (`AXButton`, `button`, `textbox`, …).
    public var role: String
    public var subrole: String?
    /// On-screen label. Screen content: it may raise caution in classification but never reaches the intent check.
    public var label: String?
    public var frame: DisplayRect?
    public var app: AppIdentity?
    /// The page the element is on, or where a link leads.
    public var url: String?
    /// Part of a browser's web content: under the web area of an accessibility tree, or any node of a DOM. Such an
    /// element is on the page, which domain grants cover, whether or not it carries a URL.
    public var isWebContent: Bool
    /// Password or other secure-entry field, as reported by the platform.
    public var isSecureInput: Bool
    /// Declared input purpose such as an HTML `autocomplete` token (`cc-number`, `current-password`).
    public var inputPurpose: String?
    /// The field's current value, as the tree shows it. Screen content; `wait-for` reads it, the gates never do.
    public var value: String?
    public var isFocused: Bool

    public init(
        id: String,
        role: String,
        subrole: String? = nil,
        label: String? = nil,
        frame: DisplayRect? = nil,
        app: AppIdentity? = nil,
        url: String? = nil,
        isWebContent: Bool = false,
        isSecureInput: Bool = false,
        inputPurpose: String? = nil,
        value: String? = nil,
        isFocused: Bool = false
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.label = label
        self.frame = frame
        self.app = app
        self.url = url
        self.isWebContent = isWebContent
        self.isSecureInput = isSecureInput
        self.inputPurpose = inputPurpose
        self.value = value
        self.isFocused = isFocused
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        frame = try container.decodeIfPresent(DisplayRect.self, forKey: .frame)
        app = try container.decodeIfPresent(AppIdentity.self, forKey: .app)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        isWebContent = try container.decodeIfPresent(Bool.self, forKey: .isWebContent) ?? false
        isSecureInput = try container.decode(Bool.self, forKey: .isSecureInput)
        inputPurpose = try container.decodeIfPresent(String.self, forKey: .inputPurpose)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        isFocused = try container.decode(Bool.self, forKey: .isFocused)
    }
}

public struct ObservationTree: Sendable, Codable, Hashable {
    /// Compact text for the model.
    public var text: String
    /// Element refs for the harness, keyed by the ids that appear in `text`.
    public var elements: [String: ElementRef]
    public var capturedAt: Date
    /// Why the tree is partial, when a traversal budget or deadline cut it short.
    public var truncated: String?
    /// Set when the observation asked to diff against an earlier one: what the model sees instead of `text`.
    /// `text` stays the full tree, as the base for later diffs.
    public var diff: ObservationTreeDiff?
    /// The control Return would trigger from the focused field: the window's default button, or the submit element
    /// of the focused field's form. Return is classified as a press of it.
    public var returnTarget: String?

    public init(
        text: String,
        elements: [String: ElementRef],
        capturedAt: Date,
        truncated: String? = nil,
        diff: ObservationTreeDiff? = nil,
        returnTarget: String? = nil
    ) {
        self.text = text
        self.elements = elements
        self.capturedAt = capturedAt
        self.truncated = truncated
        self.diff = diff
        self.returnTarget = returnTarget
    }
}

/// A receipt for one look at the screen. Actions cite it by id and are refused when the target drifted.
///
/// Pixels and tree are captured at slightly different times; each carries its own timestamp and they are never
/// presented as one atomic state.
public struct DisplayObservation: Sendable, Codable, Hashable {
    public var id: ObservationID
    public var at: Date
    public var target: ObservationTarget
    public var image: ObservationImage?
    public var tree: ObservationTree?

    /// Screen content is always external content.
    public var untrusted: Bool { true }

    /// The coarse state digest progress is measured by; see ``ComputerUseStateDigest``. `nil` when nothing
    /// identifies the state.
    public var fingerprint: String? { ComputerUseStateDigest.of(self) }

    public init(
        id: ObservationID,
        at: Date,
        target: ObservationTarget,
        image: ObservationImage? = nil,
        tree: ObservationTree? = nil
    ) {
        self.id = id
        self.at = at
        self.target = target
        self.image = image
        self.tree = tree
    }

    public func element(_ ref: String) -> ElementRef? {
        tree?.elements[ref]
    }
}

public struct DisplayInfo: Sendable, Codable, Hashable {
    public var id: String
    public var frame: DisplayRect
    public var scaleFactor: Double
    public var isPrimary: Bool

    public init(id: String, frame: DisplayRect, scaleFactor: Double, isPrimary: Bool) {
        self.id = id
        self.frame = frame
        self.scaleFactor = scaleFactor
        self.isPrimary = isPrimary
    }
}

public struct WindowInfo: Sendable, Codable, Hashable {
    public var ref: WindowRef
    public var app: AppIdentity
    public var isFocused: Bool

    public init(ref: WindowRef, app: AppIdentity, isFocused: Bool) {
        self.ref = ref
        self.app = app
        self.isFocused = isFocused
    }
}

public struct TabInfo: Sendable, Codable, Hashable {
    public var id: String
    public var url: String
    public var isActive: Bool

    public init(id: String, url: String, isActive: Bool) {
        self.id = id
        self.url = url
        self.isActive = isActive
    }
}

public struct TargetLayout: Sendable, Codable, Hashable {
    public var displays: [DisplayInfo]
    /// The windows of granted apps, front to back. `nil` when the target can't list windows, which is not the same
    /// as listing none.
    public var windows: [WindowInfo]?
    public var tabs: [TabInfo]
    /// The app that input naming no target goes to. It need not be frontmost: a target on a shared desktop
    /// reports the granted app it works in, not the harness's own app in front of it.
    public var focusedApp: AppIdentity?

    public init(displays: [DisplayInfo], windows: [WindowInfo]? = nil, tabs: [TabInfo] = [], focusedApp: AppIdentity? = nil) {
        self.displays = displays
        self.windows = windows
        self.tabs = tabs
        self.focusedApp = focusedApp
    }
}
