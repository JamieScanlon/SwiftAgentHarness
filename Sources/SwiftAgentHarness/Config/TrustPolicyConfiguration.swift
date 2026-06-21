import Foundation
import Logging

public enum TrustPolicyMode: String, Sendable, Codable, CaseIterable {
    case none
    case gateExecution
    case downgradeContext
    case gateAndDowngrade
}

public struct TrustPolicyConfiguration: Sendable {
    public var mode: TrustPolicyMode
    public var safeDefaultClass: TrustPolicyClass

    public init(
        mode: TrustPolicyMode = .none,
        safeDefaultClass: TrustPolicyClass = .lowTrust
    ) {
        self.mode = mode
        self.safeDefaultClass = safeDefaultClass
    }

    public static let disabled = TrustPolicyConfiguration(mode: .none, safeDefaultClass: .lowTrust)

    public func shouldGateExecution(for trustClass: TrustPolicyClass) -> Bool {
        guard trustClass == .lowTrust else { return false }
        switch mode {
        case .gateExecution, .gateAndDowngrade:
            return true
        case .none, .downgradeContext:
            return false
        }
    }

    public func shouldDowngradeContext(for trustClass: TrustPolicyClass) -> Bool {
        guard trustClass == .lowTrust else { return false }
        switch mode {
        case .downgradeContext, .gateAndDowngrade:
            return true
        case .none, .gateExecution:
            return false
        }
    }

    public static func loadFromPromptConfigBundle(logger: Logger? = nil) -> TrustPolicyConfiguration {
        guard let url = Bundle.module.url(forResource: "PromptConfig", withExtension: "json") else {
            return .disabled
        }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["trustPolicy"] as? [String: Any]
        else {
            return .disabled
        }

        let mode = (block["mode"] as? String)
            .flatMap(TrustPolicyMode.init(rawValue:))
            ?? .none
        let safeDefaultClass = (block["safeDefaultClass"] as? String)
            .flatMap(TrustPolicyClass.init(rawValue:))
            ?? .lowTrust
        if block["mode"] != nil && TrustPolicyMode(rawValue: (block["mode"] as? String) ?? "") == nil {
            logger?.warning("Unknown trustPolicy.mode in PromptConfig.json; using .none")
        }
        if block["safeDefaultClass"] != nil && TrustPolicyClass(rawValue: (block["safeDefaultClass"] as? String) ?? "") == nil {
            logger?.warning("Unknown trustPolicy.safeDefaultClass in PromptConfig.json; using low_trust")
        }
        return TrustPolicyConfiguration(mode: mode, safeDefaultClass: safeDefaultClass)
    }

    public func applyingOverrides(
        modeRawOverride: String?,
        safeDefaultClassRawOverride: String?
    ) -> TrustPolicyConfiguration {
        var out = self
        if let raw = modeRawOverride,
           let mode = TrustPolicyMode(rawValue: raw) {
            out.mode = mode
        }
        if let raw = safeDefaultClassRawOverride,
           let klass = TrustPolicyClass(rawValue: raw) {
            out.safeDefaultClass = klass
        }
        return out
    }
}
