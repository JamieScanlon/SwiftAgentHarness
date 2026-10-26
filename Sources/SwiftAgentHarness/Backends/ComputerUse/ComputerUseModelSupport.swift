import EasyJSON
import Foundation

/// The `computer-use` feature of a model's `generate` profile, read into typed values.
///
/// The feature is a versioned key, not a boolean: `{supported, version, params: {coordinates, maxEdgePx, …}}`.
/// The version names the vendor toolset; `coordinates` is the dialect the model emits; `maxEdgePx` caps screenshot
/// size and `maxPixels` its area; `keepRecentScreenshots` and `pruneEvery` override the screenshot retention defaults.
public struct ComputerUseModelSupport: Sendable, Hashable {
    public static let featureKey = "computer-use"

    public var version: String?
    public var coordinateMode: ComputerUseCoordinateMode
    /// The tighter of the feature's `maxEdgePx` and the contract's `maxImageEdgePx`.
    public var maxImageEdgePx: Int?
    public var maxImageTokens: Int?
    public var maxPixels: Int?
    public var keepRecentScreenshots: Int?
    public var pruneEvery: Int?

    /// `nil` when the profile has no supported `computer-use` feature.
    public init?(profile: ContractProfile) {
        guard let feature = profile.feature(Self.featureKey) else { return nil }
        version = feature.version
        coordinateMode = Self.coordinateMode(feature.param("coordinates"))
        maxImageEdgePx = [Self.int(feature.param("maxEdgePx")), profile.limits.maxImageEdgePx].compactMap { $0 }.min()
        maxImageTokens = profile.limits.maxImageTokens
        maxPixels = Self.int(feature.param("maxPixels"))
        keepRecentScreenshots = Self.int(feature.param("keepRecentScreenshots"))
        pruneEvery = Self.int(feature.param("pruneEvery"))
    }

    private static func coordinateMode(_ json: JSON?) -> ComputerUseCoordinateMode {
        guard case .string(let raw)? = json else { return .imagePixels }
        switch raw.lowercased() {
        case "normalized", "normalized-1000", "normalized-999", "grid-1000": return .normalized1000
        default: return .imagePixels
        }
    }

    static func int(_ json: JSON?) -> Int? {
        switch json {
        case .integer(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int(value)
        default: return nil
        }
    }
}

extension ContractProfile {
    /// The longest image edge this offering accepts: the tighter of `limits.maxImageEdgePx` and a computer-use
    /// feature's `maxEdgePx`.
    var effectiveMaxImageEdgePx: Int? {
        if let support = ComputerUseModelSupport(profile: self) { return support.maxImageEdgePx }
        return limits.maxImageEdgePx
    }
}

extension ObservationImageLimit {
    /// Used when the bound model declares no image cap.
    public static let defaultLongEdgePx = 1_200

    /// The screenshot size the bound model accepts. Screenshots are resized harness-side to this before they are
    /// sent; vendors are not relied on to downscale.
    public init(model profile: ContractProfile?) {
        self.init(
            longEdgePx: profile?.effectiveMaxImageEdgePx ?? Self.defaultLongEdgePx,
            maxVisualTokens: profile?.limits.maxImageTokens,
            maxPixels: profile.flatMap { ComputerUseModelSupport(profile: $0) }?.maxPixels
        )
    }
}

extension ComputerUseSessionConfiguration {
    /// Caps screenshots at the tool-result pipeline's inline-image edge. Screenshots are never resized after
    /// capture, so one over the pipeline's cap would reach the model as a marker instead of an image.
    mutating func clampImageLimit(toLongEdge pipelineEdge: Int) {
        guard pipelineEdge > 0, var limit = imageLimit, limit.longEdgePx > pipelineEdge else { return }
        limit.longEdgePx = pipelineEdge
        imageLimit = limit
    }

    /// A configuration whose coordinate dialect and screenshot size come from the bound model's `generate` profile.
    public init(task: ComputerUseTaskContext, model profile: ContractProfile?) {
        self.init(
            task: task,
            coordinateMode: profile.flatMap { ComputerUseModelSupport(profile: $0) }?.coordinateMode ?? .imagePixels,
            imageLimit: ObservationImageLimit(model: profile)
        )
    }
}
