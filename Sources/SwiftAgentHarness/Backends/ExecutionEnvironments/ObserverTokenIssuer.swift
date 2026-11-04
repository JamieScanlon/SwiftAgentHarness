import Foundation

/// Mints the short-lived credentials observer links carry, for sandbox backends and display targets alike.
public enum ObserverTokenIssuer {
    /// `bytes` of system randomness, base64url without padding.
    public static func token(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let random = (0..<max(1, bytes)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
