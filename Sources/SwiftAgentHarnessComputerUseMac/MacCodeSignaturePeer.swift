#if os(macOS)
import Foundation
import Security
import SwiftAgentHarness

public enum MacCodeSignatureError: Error, Sendable, Equatable {
    case invalidRequirement(String, status: Int32)
    case unsigned(status: Int32)
    case noTeamIdentifier
}

extension DisplayHostPeerRequirement {
    /// Peers whose running code satisfies a code-signing requirement, such as
    /// `anchor apple generic and certificate leaf[subject.OU] = "TEAMID1234"`. The check uses the peer's audit
    /// token, so it names the process actually connected rather than one with a reused pid; peers without a
    /// token are refused.
    public static func codeSignature(_ requirement: String) throws -> Self {
        _ = try MacCodeSignature.compile(requirement)
        return Self { peer in MacCodeSignature.peer(peer, satisfies: requirement) }
    }

    /// Peers signed by this process's Developer ID or App Store team: the usual check when one team ships both
    /// the harness and the host.
    public static func sameTeamAsThisProcess() throws -> Self {
        guard let team = MacCodeSignature.teamIdentifierOfThisProcess() else { throw MacCodeSignatureError.noTeamIdentifier }
        return try codeSignature(#"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#)
    }
}

enum MacCodeSignature {
    static func compile(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw MacCodeSignatureError.invalidRequirement(text, status: status)
        }
        return requirement
    }

    static func peer(_ peer: DisplayHostPeer, satisfies text: String) -> Bool {
        guard let words = peer.auditToken, words.count == 8, let requirement = try? compile(text) else { return false }
        let token = words.withUnsafeBytes { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func designatedRequirementOfThisProcess() throws -> String {
        let code = try staticCodeOfThisProcess()
        var requirement: SecRequirement?
        var status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw MacCodeSignatureError.unsigned(status: status) }
        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else { throw MacCodeSignatureError.unsigned(status: status) }
        return text as String
    }

    static func teamIdentifierOfThisProcess() -> String? {
        signingInformation()?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func signingIdentifierOfThisProcess() -> String? {
        signingInformation()?[kSecCodeInfoIdentifier as String] as? String
    }

    private static func signingInformation() -> [String: Any]? {
        guard let code = try? staticCodeOfThisProcess() else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }

    private static func staticCodeOfThisProcess() throws -> SecStaticCode {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw MacCodeSignatureError.unsigned(status: status) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw MacCodeSignatureError.unsigned(status: status) }
        return staticCode
    }
}
#endif
