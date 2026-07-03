import Foundation
import Logging
import SwiftAgentKit
import Testing
import Vapor
import VaporTesting
@testable import SwiftAgentHarness

@Suite("API safe relative filename")
struct APISafeRelativeFilenameTests {
    @Test func acceptsUploadStyleFilename() {
        #expect(APISafeRelativeFilename.validate("550e8400-e29b-41d4-a716-446655440000_note.png") == "550e8400-e29b-41d4-a716-446655440000_note.png")
        #expect(APISafeRelativeFilename.validate("demo.bin") == "demo.bin")
    }

    @Test func rejectsTraversalAndSeparators() {
        #expect(APISafeRelativeFilename.validate("../escape.txt") == nil)
        #expect(APISafeRelativeFilename.validate("/absolute.txt") == nil)
        #expect(APISafeRelativeFilename.validate("nested/file.txt") == nil)
        #expect(APISafeRelativeFilename.validate("..") == nil)
        #expect(APISafeRelativeFilename.validate("") == nil)
    }
}

@Suite("API layer image loader")
struct APILayerImageLoaderTests {
    private let logger = Logger(label: "test.api-layer-image-loader")

    @Test func loadImagesRejectsPathTraversal() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-image-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sentinel = sandbox.deletingLastPathComponent().appendingPathComponent("sentinel-\(UUID().uuidString).txt")
        let sentinelBytes = Data("secret-outside-temp".utf8)
        try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }

        let traversalName = "../\(sentinel.lastPathComponent)"
        HarnessEnvironmentOverride.$overrides.withValue([:]) {
            let images = APILayerImageLoader.loadImages(names: [traversalName], logger: logger)
            #expect(images.isEmpty)
        }
    }

    @Test func loadImagesReadsValidFileUnderTemp() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(UUID().uuidString)_note.txt"
        let fileURL = tempDir.appendingPathComponent(filename)
        let payload = Data("hello-image".utf8)
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        HarnessEnvironmentOverride.$overrides.withValue([:]) {
            let images = APILayerImageLoader.loadImages(names: [filename], logger: logger)
            #expect(images.count == 1)
            #expect(images[0].imageData == payload)
            #expect(images[0].name == filename)
        }
    }

    @Test func loadImagesWithBlobStoreUsesBlobRef() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-image-blob-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionBlobStore(root: root, maxBytes: 1024 * 1024)
        let payload = Data("blob-image-bytes".utf8)
        let ref = try store.put(
            data: payload,
            durability: .ephemeral,
            originalName: "shot.png",
            mimeTypeHint: "image/png",
            trust: "user-direct",
            ttlSeconds: 120,
            lane: .inbound
        )

        HarnessEnvironmentOverride.$overrides.withValue(["SAH_SESSION_STORE_ROOT": root.path]) {
            let byId = APILayerImageLoader.loadImages(names: [ref.id], logger: logger)
            #expect(byId.count == 1)
            #expect(byId[0].imageData == payload)

            let byPath = APILayerImageLoader.loadImages(names: [SessionBlobImageRef.path(for: ref.id)], logger: logger)
            #expect(byPath.count == 1)
            #expect(byPath[0].imageData == payload)
        }
    }

    @Test func loadImagesWithBlobStoreSkipsTraversalFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-image-blob-skip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("outside-secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        HarnessEnvironmentOverride.$overrides.withValue(["SAH_SESSION_STORE_ROOT": root.path]) {
            let images = APILayerImageLoader.loadImages(names: ["../\(outside.lastPathComponent)"], logger: logger)
            #expect(images.isEmpty)
        }
    }

    @Test func loadImagesWithBlobStoreSkipsUnknownBlobId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-image-blob-miss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingBlobId = String(repeating: "a", count: 64)
        let tempFilename = "\(UUID().uuidString)_note.txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)
        try Data("should-not-load".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        HarnessEnvironmentOverride.$overrides.withValue(["SAH_SESSION_STORE_ROOT": root.path]) {
            let byMissingBlob = APILayerImageLoader.loadImages(names: [missingBlobId], logger: logger)
            #expect(byMissingBlob.isEmpty)

            let byTempName = APILayerImageLoader.loadImages(names: [tempFilename], logger: logger)
            #expect(byTempName.isEmpty)
        }
    }
}

@Suite("API upload filename validation")
struct APILayerUploadFilenameValidationTests {
    @Test("POST /api/upload rejects invalid X-File-Name")
    func uploadRejectsInvalidFileName() async throws {
        let conversation = ProtocolOnlyConversationGatewayStub()
        let runtime = ProtocolOnlyRuntimeGatewayStub()
        let modelProvider = StubModelProvider(models: [])
        let api = APILayer(port: 0)

        try await withApp { app in
            await api.configureRoutesForTesting(
                app: app,
                conversation: conversation,
                runtime: runtime,
                modelProvider: modelProvider
            )
            let payload = Data("hello upload".utf8)
            try await app.testing().test(.POST, "/api/upload", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-File-Name", value: "../etc/passwd")
                req.headers.replaceOrAdd(name: "Content-Type", value: "text/plain")
                req.body = .init(data: payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
}

private final class StubModelProvider: APILayerModelManaging, Sendable {
    let models: [Model]

    init(models: [Model]) {
        self.models = models
    }

    func getAvailableModels() async -> [Model] {
        models
    }
}
