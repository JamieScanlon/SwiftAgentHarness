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

    /// Compares two tokens in time that depends only on their lengths, not on where they first differ.
    public static func matches(_ expected: String, _ presented: String) -> Bool {
        let a = Array(expected.utf8), b = Array(presented.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
