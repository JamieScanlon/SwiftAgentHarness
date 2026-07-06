import EasyJSON
import Foundation

/// Harness-owned conversation metadata keys that clients and model tools must not write.
public enum ConversationHarnessMetadataKeys {
    private static let clientWriteDeniedPrefixes = ["subAgent"]
    private static let clientWriteDeniedExactKeys: Set<String> = ["_transformDebug"]

    public static func isClientWriteDenied(_ key: String) -> Bool {
        if clientWriteDeniedExactKeys.contains(key) { return true }
        return clientWriteDeniedPrefixes.contains { key.hasPrefix($0) }
    }

    /// Removes harness-only keys from client-supplied metadata (REST create / patch payloads).
    public static func strippingClientControlledKeys(from metadata: JSON?) -> JSON? {
        guard case .object(var object) = metadata else { return metadata }
        object = object.filter { !isClientWriteDenied($0.key) }
        return object.isEmpty ? nil : .object(object)
    }

    /// Strips denied keys from `incoming` and preserves harness-only keys already on `existing`.
    public static func mergingPreservingHarnessKeys(existing: JSON?, incoming: JSON) -> JSON {
        guard case .object(var incomingObject) = incoming else {
            return incoming
        }
        incomingObject = incomingObject.filter { !isClientWriteDenied($0.key) }
        if let existing, case .object(let existingObject) = existing {
            for (key, value) in existingObject where isClientWriteDenied(key) {
                incomingObject[key] = value
            }
        }
        return .object(incomingObject)
    }
}
