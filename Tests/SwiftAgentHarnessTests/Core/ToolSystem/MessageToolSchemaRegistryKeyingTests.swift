import Foundation
import EasyJSON
import Testing
@testable import SwiftAgentHarness

/// The registry is keyed by surface id now. It used to be a whole-array replace, which had two
/// consequences: a second surface registering silently wiped the first (the TUI plugin declines to
/// register at all because of it), and there was nothing to unregister *by* — so a paused channel
/// kept advertising its media params and runtime channel teardown was impossible.
/// Serialized: the registry is a process-global, and these tests assert on the *merged* output of
/// every registered surface. Unique surface ids are not enough — two tests registering the same
/// param name concurrently make each other's absence assertions flaky.
@Suite("MessageToolSchemaRegistry keying", .serialized)
struct MessageToolSchemaRegistryKeyingTests {
    private func schema(action: String, param: String) -> MessageToolActionSchema {
        MessageToolActionSchema(
            action: action,
            mediaParams: [MessageToolMediaParamDescriptor(name: param, type: "string", description: param)]
        )
    }

    private func mediaKeys() -> Set<String> {
        let merged = MessageToolSchemaRegistry.mergedRawSchema(base: .object([:]))
        guard case .object(let root) = merged,
              case .object(let properties)? = root["properties"],
              case .object(let media)? = properties["media"],
              case .object(let mediaProperties)? = media["properties"]
        else { return [] }
        return Set(mediaProperties.keys)
    }

    /// Two surfaces coexist. Under the old replace-everything behaviour the second registration
    /// erased the first.
    @Test("surfaces do not overwrite each other")
    func surfacesCoexist() {
        let run = UUID().uuidString
        let a = "keying-a-\(UUID().uuidString)"
        let b = "keying-b-\(UUID().uuidString)"
        defer {
            MessageToolSchemaRegistry.unregister(surfaceID: a)
            MessageToolSchemaRegistry.unregister(surfaceID: b)
        }
        MessageToolSchemaRegistry.register(surfaceID: a, actionSchemas: [schema(action: "post", param: "alphaParam-\(run)")])
        MessageToolSchemaRegistry.register(surfaceID: b, actionSchemas: [schema(action: "post", param: "betaParam-\(run)")])
        let keys = mediaKeys()
        #expect(keys.contains("alphaParam-\(run)"))
        #expect(keys.contains("betaParam-\(run)"))
    }

    /// The unblock: withdrawing one surface leaves the others standing.
    @Test("unregister removes only its own surface")
    func unregisterIsScoped() {
        let run = UUID().uuidString
        let a = "keying-a-\(UUID().uuidString)"
        let b = "keying-b-\(UUID().uuidString)"
        defer {
            MessageToolSchemaRegistry.unregister(surfaceID: a)
            MessageToolSchemaRegistry.unregister(surfaceID: b)
        }
        MessageToolSchemaRegistry.register(surfaceID: a, actionSchemas: [schema(action: "post", param: "alphaParam-\(run)")])
        MessageToolSchemaRegistry.register(surfaceID: b, actionSchemas: [schema(action: "post", param: "betaParam-\(run)")])
        MessageToolSchemaRegistry.unregister(surfaceID: a)
        let keys = mediaKeys()
        #expect(keys.contains("alphaParam-\(run)") == false)
        #expect(keys.contains("betaParam-\(run)"))
    }

    /// Re-registering replaces that surface's entry rather than accumulating — a channel that
    /// reloads with a changed descriptor must not leave the old params behind.
    @Test("re-registering a surface replaces its entry")
    func reRegisterReplaces() {
        let surface = "keying-\(UUID().uuidString)"
        defer { MessageToolSchemaRegistry.unregister(surfaceID: surface) }
        MessageToolSchemaRegistry.register(surfaceID: surface, actionSchemas: [schema(action: "post", param: "oldParam")])
        MessageToolSchemaRegistry.register(surfaceID: surface, actionSchemas: [schema(action: "post", param: "newParam")])
        let keys = mediaKeys()
        #expect(keys.contains("oldParam") == false)
        #expect(keys.contains("newParam"))
    }

    /// Registering an empty set is a withdrawal, not an empty entry — otherwise a surface with no
    /// descriptors would leave a permanent key behind.
    @Test("registering nothing withdraws the surface")
    func emptyRegistrationWithdraws() {
        let surface = "keying-\(UUID().uuidString)"
        MessageToolSchemaRegistry.register(surfaceID: surface, actionSchemas: [schema(action: "post", param: "goneParam")])
        MessageToolSchemaRegistry.register(surfaceID: surface, actionSchemas: [])
        #expect(mediaKeys().contains("goneParam") == false)
    }

    @Test("unregistering an unknown surface is harmless")
    func unregisterUnknownIsIdempotent() {
        MessageToolSchemaRegistry.unregister(surfaceID: "never-registered-\(UUID().uuidString)")
    }
}
