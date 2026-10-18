import EasyJSON
import Foundation

/// Well-known `decide` feature keys (spec: decision-models § Capability descriptor).
public enum DecisionFeatureKey {
    public static let questionTypes = "questionTypes"
    public static let questionSet = "questionSet"
    public static let images = "images"
    public static let longContext = "longContext"
    public static let calibration = "calibration"
    public static let languages = "languages"
    /// Per-server quirk: response wrapped in a platform envelope (`params.unwrap`).
    public static let envelope = "envelope"
    /// Per-server quirk: whether to send `model` (`params.mode`: `send` | `omit`).
    public static let modelField = "modelField"
    /// Endpoint path override (`params.path`).
    public static let endpoint = "endpoint"
    /// Request body compression (`params.encoding`: `gzip`).
    public static let compression = "compression"
}

public enum DecisionImagesEncoding: String, Sendable, Codable, Hashable {
    case assets
    case imagesArray = "images-array"
    case parts
}

/// Per-server quirks encoded as binding config rather than code branches.
public struct DecisionSurfaceOptions: Sendable, Equatable {
    public var questionKinds: Set<DecisionQuestionKind>
    public var unwrapKey: String?
    public var sendModel: Bool
    public var imagesSupported: Bool
    public var imagesEncoding: DecisionImagesEncoding
    public var imagesOptInHeader: String?
    public var imageWindow: DecisionImageNormalizer.Window?
    public var longContextOptInHeader: String?
    /// Context size above which the long-context opt-in header is required.
    public var standardContextTokens: Int?
    public var maxQuestionsPerCall: Int?
    public var maxOptions: Int?
    public var path: String
    public var gzip: Bool
    public var languagesStrong: [String]
    public var languagesWeak: [String]

    public init(profile: ContractProfile) {
        let defaultKinds: Set<DecisionQuestionKind> = profile.surface == .openAIDecisions
            ? [.yesNo, .choice, .score]
            : [.yesNo, .choice, .score, .box]
        if let kinds = profile.feature(DecisionFeatureKey.questionTypes)?.stringArrayParam("kinds") {
            questionKinds = Set(kinds.compactMap(DecisionQuestionKind.init(rawValue:)))
        } else {
            questionKinds = defaultKinds
        }
        unwrapKey = profile.feature(DecisionFeatureKey.envelope)?.stringParam("unwrap")
        sendModel = profile.feature(DecisionFeatureKey.modelField)?.stringParam("mode") != "omit"
        let images = profile.feature(DecisionFeatureKey.images)
        imagesSupported = images != nil
        imagesEncoding = images?.stringParam("encoding").flatMap(DecisionImagesEncoding.init(rawValue:)) ?? .assets
        imagesOptInHeader = images?.stringParam("optInHeader")
        if let edge = images?.intPairParam("edgePx"), let total = images?.intPairParam("totalPixels"),
           edge.0 <= edge.1, total.0 <= total.1 {
            imageWindow = DecisionImageNormalizer.Window(edgePx: edge.0...edge.1, totalPixels: total.0...total.1)
        } else {
            imageWindow = nil
        }
        let longContext = profile.feature(DecisionFeatureKey.longContext)
        longContextOptInHeader = longContext?.stringParam("optInHeader")
        standardContextTokens = profile.limits.contextTokens
        maxQuestionsPerCall = profile.limits.maxItemsPerCall
        maxOptions = profile.limits.maxOptions
        let defaultPath = profile.surface == .openAIDecisions ? "v1/decisions" : "v1/systemone"
        path = profile.feature(DecisionFeatureKey.endpoint)?.stringParam("path") ?? defaultPath
        gzip = profile.feature(DecisionFeatureKey.compression)?.stringParam("encoding") == "gzip"
        let languages = profile.feature(DecisionFeatureKey.languages)
        languagesStrong = languages?.stringArrayParam("strong") ?? []
        languagesWeak = languages?.stringArrayParam("weak") ?? []
    }

    /// Why this surface cannot answer `request`, or `nil` (used by the Pool's hard filter).
    public func rejection(for request: DecisionRequest) -> String? {
        if let kind = request.questionKinds.subtracting(questionKinds).sorted(by: { $0.rawValue < $1.rawValue }).first {
            return "question kind \(kind.rawValue) unsupported"
        }
        if !request.assets.isEmpty && !imagesSupported {
            return "image assets unsupported"
        }
        if let maxOptions, request.maxOptionCount > maxOptions {
            return "\(request.maxOptionCount) options exceed maxOptions \(maxOptions)"
        }
        return nil
    }
}

/// Builds the `decide` capability descriptor used by catalogs and host runtime configs.
public enum DecisionProfiles {
    public static func systemOne(
        questionKinds: [DecisionQuestionKind] = [.yesNo, .choice, .score, .box],
        images: FeatureSupport? = nil,
        longContext: FeatureSupport? = nil,
        calibration: FeatureSupport = FeatureSupport(params: ["method": .string("vendor-trained")]),
        languages: FeatureSupport? = nil,
        extraFeatures: [String: FeatureSupport] = [:],
        limits: ContractLimits = ContractLimits(contextTokens: 65_536, maxOptions: 255, scoreLevels: 2...10)
    ) -> ContractProfile {
        profile(
            surface: .systemOne, questionKinds: questionKinds, images: images, longContext: longContext,
            calibration: calibration, languages: languages, extraFeatures: extraFeatures, limits: limits
        )
    }

    public static func openAIDecisions(
        images: FeatureSupport? = FeatureSupport(params: ["encoding": .string("parts")]),
        calibration: FeatureSupport = FeatureSupport(params: ["method": .string("vendor-trained")]),
        languages: FeatureSupport? = nil,
        extraFeatures: [String: FeatureSupport] = [:],
        limits: ContractLimits = ContractLimits(maxOptions: 255, scoreLevels: 2...10)
    ) -> ContractProfile {
        profile(
            surface: .openAIDecisions, questionKinds: [.yesNo, .choice, .score], images: images, longContext: nil,
            calibration: calibration, languages: languages, extraFeatures: extraFeatures, limits: limits
        )
    }

    private static func profile(
        surface: ContractSurface,
        questionKinds: [DecisionQuestionKind],
        images: FeatureSupport?,
        longContext: FeatureSupport?,
        calibration: FeatureSupport,
        languages: FeatureSupport?,
        extraFeatures: [String: FeatureSupport],
        limits: ContractLimits
    ) -> ContractProfile {
        var features = extraFeatures
        features[DecisionFeatureKey.questionTypes] = FeatureSupport(
            params: ["kinds": .array(questionKinds.map { .string($0.rawValue) })]
        )
        features[DecisionFeatureKey.questionSet] = features[DecisionFeatureKey.questionSet]
            ?? FeatureSupport(params: ["mode": .string("open")])
        features[DecisionFeatureKey.calibration] = calibration
        if let images { features[DecisionFeatureKey.images] = images }
        if let longContext { features[DecisionFeatureKey.longContext] = longContext }
        if let languages { features[DecisionFeatureKey.languages] = languages }
        var input: [ContractMediaType] = [.text, .json]
        if images != nil { input.append(.image) }
        var output: [ContractMediaType] = [.distribution]
        if questionKinds.contains(.box) { output.append(.bbox) }
        return ContractProfile(
            contract: .decide,
            surface: surface,
            interaction: [.unary],
            input: input,
            output: output,
            guarantee: .calibratedDistribution,
            features: features,
            limits: limits
        )
    }
}
