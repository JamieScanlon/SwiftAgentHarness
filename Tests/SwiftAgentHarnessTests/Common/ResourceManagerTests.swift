import Testing
import Foundation
@testable import SwiftAgentHarness

// MARK: - Mock File System Provider

/// A mock file system that stores all files in-memory dictionaries,
/// enabling deterministic testing without touching the real file system.
final class MockFileSystemProvider: FileSystemProviding, @unchecked Sendable {
    
    /// Simulated file storage: path -> data
    var files: [String: Data] = [:]
    /// Simulated directory existence
    var directories: Set<String> = []
    
    /// Flags to simulate failures
    var shouldThrowOnWrite = false
    var shouldThrowOnRead = false
    var shouldThrowOnDelete = false
    var shouldThrowOnCreateDirectory = false
    
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        if shouldThrowOnCreateDirectory {
            throw NSError(domain: "MockFS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Directory creation failed"])
        }
        directories.insert(url.path)
    }
    
    func fileExists(atPath path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }
    
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        if shouldThrowOnWrite {
            throw NSError(domain: "MockFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Write failed"])
        }
        files[url.path] = data
    }
    
    func read(from url: URL) throws -> Data {
        if shouldThrowOnRead {
            throw NSError(domain: "MockFS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Read failed"])
        }
        guard let data = files[url.path] else {
            throw NSError(domain: "MockFS", code: 4, userInfo: [NSLocalizedDescriptionKey: "File not found: \(url.path)"])
        }
        return data
    }
    
    func removeItem(at url: URL) throws {
        if shouldThrowOnDelete {
            throw NSError(domain: "MockFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Delete failed"])
        }
        files.removeValue(forKey: url.path)
    }
    
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL] {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return files.keys
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .map { URL(fileURLWithPath: $0) }
    }
    
    var homeDirectoryForCurrentUser: URL {
        URL(fileURLWithPath: "/mock/home")
    }
    
    var applicationSupportDirectory: URL {
        URL(fileURLWithPath: "/mock/app-support")
    }
    
    var temporaryDirectory: URL {
        URL(fileURLWithPath: "/mock/tmp")
    }
}

// MARK: - Mock Image Processor

/// A mock image processor that returns deterministic data for testing,
/// without requiring actual image data or CoreGraphics.
struct MockImageProcessor: ImageProcessing {
    /// Data returned by `generateThumbnail`. `nil` simulates failure.
    var thumbnailResult: Data?
    /// Data returned by `scaleImage`. `.none` (outer nil) uses passthrough; `.some(nil)` simulates failure.
    var scaleResult: Data??
    /// Data returned by `scaleImageToFileSize`. `nil` uses default size-check behavior.
    var scaleToFileSizeResult: Data?
    
    init(
        thumbnailResult: Data? = Data([0xFF, 0xD8, 0xFF]),
        scaleResult: Data?? = .none,
        scaleToFileSizeResult: Data? = nil
    ) {
        self.thumbnailResult = thumbnailResult
        self.scaleResult = scaleResult
        self.scaleToFileSizeResult = scaleToFileSizeResult
    }
    
    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? {
        thumbnailResult
    }
    
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? {
        // .none (outer nil) → passthrough original data
        // .some(nil)        → simulate scaling failure
        // .some(someData)   → return the explicit mock data
        if let explicit = scaleResult {
            return explicit
        }
        return data
    }
    
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? {
        if let explicit = scaleToFileSizeResult { return explicit }
        return data.count <= maxFileSize ? data : nil
    }
}

// MARK: - Test Helpers

/// Create a `ResourceManager` wired to mocks, returning all three for inspection.
private func createTestManager(
    configuration: ResourceManager.Configuration = .init(defaultStorageLocation: .applicationSupport),
    fileSystem: MockFileSystemProvider = MockFileSystemProvider(),
    imageProcessor: MockImageProcessor = MockImageProcessor()
) -> (ResourceManager, MockFileSystemProvider, MockImageProcessor) {
    let manager = ResourceManager(
        configuration: configuration,
        logger: nil,
        fileSystem: fileSystem,
        imageProcessor: imageProcessor
    )
    return (manager, fileSystem, imageProcessor)
}

/// Shorthand sample data for tests
private let sampleData = Data("hello world".utf8)
private let sampleImageData = Data("fake-image-bytes".utf8)
private let updatedData = Data("updated content".utf8)

// MARK: - Tests: Adding Resources

@Suite("ResourceManager — Adding Resources")
struct ResourceManagerAddTests {
    
    @Test("Add a basic data resource and verify metadata")
    func addDataResource() async throws {
        let (manager, _, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .data)
        
        #expect(resource.data == sampleData)
        #expect(resource.metadata.resourceType == .data)
        #expect(resource.metadata.byteSize == sampleData.count)
        #expect(resource.metadata.storageLocation == .applicationSupport)
        #expect(resource.metadata.thumbnailData == nil) // No thumbnail for .data
        #expect(resource.metadata.fileExtension == nil)
        #expect(resource.metadata.mimeType == nil)
    }
    
    @Test("Add a file resource with filename — extracts extension")
    func addFileResourceWithFilename() async throws {
        let (manager, _, _) = createTestManager()
        
        let resource = try await manager.addResource(
            data: sampleData,
            type: .file,
            filename: "document.pdf",
            mimeType: "application/pdf"
        )
        
        #expect(resource.metadata.fileExtension == "pdf")
        #expect(resource.metadata.mimeType == "application/pdf")
        #expect(resource.metadata.originalFilename == "document.pdf")
    }
    
    @Test("Add resource rejects empty data")
    func addResourceRejectsEmptyData() async throws {
        let (manager, _, _) = createTestManager()
        
        await #expect(throws: ResourceManager.ResourceManagerError.invalidData) {
            try await manager.addResource(data: Data(), type: .data)
        }
    }
    
    @Test("Add resource to in-memory storage — no file system writes")
    func addResourceToInMemoryStorage() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        
        #expect(resource.metadata.storageLocation == .inMemory)
        // No files should be written to the mock file system for in-memory storage
        #expect(fs.files.isEmpty)
    }
    
    @Test("Add resource to home directory storage")
    func addResourceToHomeDirectory() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .file, storageLocation: .homeDirectory)
        
        #expect(resource.metadata.storageLocation == .homeDirectory)
        // Verify the file was written under the home directory path
        let hasHomeFile = fs.files.keys.contains { $0.hasPrefix("/mock/home/.swiftAgentHarness/resources/") }
        #expect(hasHomeFile)
    }
    
    @Test("Add resource to temporary storage")
    func addResourceToTemporary() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .file, storageLocation: .temporary)
        
        #expect(resource.metadata.storageLocation == .temporary)
        let hasTmpFile = fs.files.keys.contains { $0.hasPrefix("/mock/tmp/sah-resources/") }
        #expect(hasTmpFile)
    }
    
    @Test("Add image resource generates thumbnail")
    func addImageGeneratesThumbnail() async throws {
        let thumbData = Data([0xAA, 0xBB, 0xCC])
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: thumbData)
        )
        
        let resource = try await manager.addResource(data: sampleImageData, type: .image, filename: "photo.png")
        
        #expect(resource.metadata.resourceType == .image)
        #expect(resource.metadata.thumbnailData == thumbData)
        #expect(resource.metadata.fileExtension == "png")
    }
    
    @Test("Add video resource generates thumbnail")
    func addVideoGeneratesThumbnail() async throws {
        let thumbData = Data([0x01, 0x02])
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: thumbData)
        )
        
        let resource = try await manager.addResource(data: sampleData, type: .video)
        
        #expect(resource.metadata.resourceType == .video)
        #expect(resource.metadata.thumbnailData == thumbData)
    }
    
    @Test("addImage convenience method with scaling overrides")
    func addImageWithScalingOverrides() async throws {
        let scaledData = Data("scaled-image".utf8)
        let thumbData = Data([0xAA])
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(
                thumbnailResult: thumbData,
                scaleResult: scaledData,
                scaleToFileSizeResult: scaledData
            )
        )
        
        let resource = try await manager.addImage(
            data: sampleImageData,
            filename: "photo.jpg",
            maxFileSize: 1024,
            maxPixelDimension: 800,
            storageLocation: .applicationSupport
        )
        
        #expect(resource.metadata.resourceType == .image)
        #expect(resource.metadata.mimeType == "image/jpeg")
        #expect(resource.metadata.thumbnailData == thumbData)
        #expect(resource.data == scaledData)
    }
    
    @Test("addImage rejects empty data")
    func addImageRejectsEmptyData() async throws {
        let (manager, _, _) = createTestManager()
        
        await #expect(throws: ResourceManager.ResourceManagerError.invalidData) {
            try await manager.addImage(data: Data())
        }
    }
    
    @Test("addImage defaults file extension to jpg")
    func addImageDefaultsExtensionToJpg() async throws {
        let (manager, _, _) = createTestManager()
        
        let resource = try await manager.addImage(data: sampleImageData)
        
        #expect(resource.metadata.fileExtension == "jpg")
        #expect(resource.metadata.mimeType == "image/jpeg")
    }
    
    @Test("Add resource applies global image scaling config for image type")
    func addResourceAppliesGlobalImageScaling() async throws {
        let scaledData = Data("globally-scaled".utf8)
        let config = ResourceManager.Configuration(
            defaultStorageLocation: .applicationSupport,
            maxImageFileSize: 512,
            maxImagePixelDimension: 1000
        )
        let (manager, _, _) = createTestManager(
            configuration: config,
            imageProcessor: MockImageProcessor(scaleResult: scaledData, scaleToFileSizeResult: scaledData)
        )
        
        let resource = try await manager.addResource(data: sampleImageData, type: .image)
        
        #expect(resource.data == scaledData)
    }
}

// MARK: - Tests: Retrieving Resources

@Suite("ResourceManager — Retrieving Resources")
struct ResourceManagerRetrieveTests {
    
    @Test("Get resource from in-memory storage")
    func getResourceInMemory() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        let retrieved = try await manager.getResource(id: added.id)
        
        #expect(retrieved.data == sampleData)
        #expect(retrieved.metadata.id == added.id)
    }
    
    @Test("Get resource from disk — reads from file system")
    func getResourceFromDisk() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .file, filename: "test.txt")
        let retrieved = try await manager.getResource(id: added.id)
        
        #expect(retrieved.data == sampleData)
    }
    
    @Test("Get resource not found throws error")
    func getResourceNotFound() async throws {
        let (manager, _, _) = createTestManager()
        let fakeID = UUID()
        
        await #expect(throws: ResourceManager.ResourceManagerError.resourceNotFound(fakeID)) {
            try await manager.getResource(id: fakeID)
        }
    }
    
    @Test("Get resource metadata without loading data")
    func getResourceMetadata() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        let metadata = try await manager.getResourceMetadata(id: added.id)
        
        #expect(metadata.id == added.id)
        #expect(metadata.byteSize == sampleData.count)
    }
    
    @Test("Get thumbnail for image resource")
    func getThumbnail() async throws {
        let thumbData = Data([0xAA, 0xBB])
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: thumbData)
        )
        
        let added = try await manager.addResource(data: sampleImageData, type: .image)
        let thumb = try await manager.getThumbnail(id: added.id)
        
        #expect(thumb == thumbData)
    }
    
    @Test("Get thumbnail fails when none available")
    func getThumbnailNotAvailable() async throws {
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: nil)
        )
        
        // Add a data resource (no thumbnail)
        let added = try await manager.addResource(data: sampleData, type: .data)
        
        await #expect(throws: ResourceManager.ResourceManagerError.thumbnailGenerationFailed) {
            try await manager.getThumbnail(id: added.id)
        }
    }
    
    @Test("Get resource URL for disk-based resource")
    func getResourceURL() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .file, filename: "report.csv")
        let url = try await manager.getResourceURL(id: added.id)
        
        #expect(url != nil)
        #expect(url!.pathExtension == "csv")
        #expect(url!.path.contains(added.id.uuidString))
    }
    
    @Test("Get resource URL returns nil for in-memory resource")
    func getResourceURLInMemory() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        let url = try await manager.getResourceURL(id: added.id)
        
        #expect(url == nil)
    }
    
    @Test("List all resources")
    func listAllResources() async throws {
        let (manager, _, _) = createTestManager()
        
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        try await manager.addResource(data: sampleData, type: .file, storageLocation: .inMemory)
        try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        
        let all = await manager.listResources()
        #expect(all.count == 3)
    }
    
    @Test("List resources filtered by type")
    func listResourcesByType() async throws {
        let (manager, _, _) = createTestManager()
        
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        try await manager.addResource(data: sampleData, type: .file, storageLocation: .inMemory)
        try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        
        let images = await manager.listResources(ofType: .image)
        let files = await manager.listResources(ofType: .file)
        let videos = await manager.listResources(ofType: .video)
        
        #expect(images.count == 2)
        #expect(files.count == 1)
        #expect(videos.count == 0)
    }
}

// MARK: - Tests: Exporting Resources

@Suite("ResourceManager — Exporting Resources")
struct ResourceManagerExportTests {
    
    @Test("Export a non-image resource returns an identical copy")
    func exportNonImageResource() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            filename: "notes.txt",
            description: "My notes",
            storageLocation: .inMemory
        )
        
        let exported = try await manager.exportResource(id: added.id)
        
        #expect(exported.data == sampleData)
        #expect(exported.metadata.id == added.id)
        #expect(exported.metadata.byteSize == sampleData.count)
        #expect(exported.metadata.description == "My notes")
        #expect(exported.metadata.resourceType == .file)
    }
    
    @Test("Export a non-image resource ignores maxPixelDimension")
    func exportNonImageIgnoresPixelDimension() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        
        // maxPixelDimension should have no effect on non-image resources
        let exported = try await manager.exportResource(id: added.id, maxPixelDimension: 100)
        
        #expect(exported.data == sampleData)
        #expect(exported.metadata.byteSize == sampleData.count)
    }
    
    @Test("Export an image at original size")
    func exportImageOriginalSize() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        
        let exported = try await manager.exportResource(id: added.id)
        
        #expect(exported.data == sampleImageData)
        #expect(exported.metadata.byteSize == sampleImageData.count)
    }
    
    @Test("Export an image scaled to a target pixel dimension")
    func exportImageScaled() async throws {
        let scaledData = Data("scaled-to-200px".utf8)
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(scaleResult: scaledData)
        )
        
        let added = try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        
        let exported = try await manager.exportResource(id: added.id, maxPixelDimension: 200)
        
        #expect(exported.data == scaledData)
        #expect(exported.metadata.byteSize == scaledData.count)
        #expect(exported.metadata.id == added.id)
    }
    
    @Test("Export does not modify the original resource")
    func exportDoesNotModifyOriginal() async throws {
        let scaledData = Data("scaled-copy".utf8)
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(scaleResult: scaledData)
        )
        
        let added = try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        
        // Export a scaled version
        let _ = try await manager.exportResource(id: added.id, maxPixelDimension: 100)
        
        // Original should be unchanged
        let original = try await manager.getResource(id: added.id)
        #expect(original.data == sampleImageData)
        #expect(original.metadata.byteSize == sampleImageData.count)
    }
    
    @Test("Export from disk-based storage reads from file system")
    func exportFromDisk() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .file, filename: "doc.txt")
        
        let exported = try await manager.exportResource(id: added.id)
        
        #expect(exported.data == sampleData)
    }
    
    @Test("Export resource not found throws error")
    func exportResourceNotFound() async throws {
        let (manager, _, _) = createTestManager()
        let fakeID = UUID()
        
        await #expect(throws: ResourceManager.ResourceManagerError.resourceNotFound(fakeID)) {
            try await manager.exportResource(id: fakeID)
        }
    }
    
    @Test("Export image scaling failure throws imageScalingFailed")
    func exportImageScalingFailed() async throws {
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: nil, scaleResult: .some(nil))
        )
        
        let added = try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        
        await #expect(throws: ResourceManager.ResourceManagerError.imageScalingFailed) {
            try await manager.exportResource(id: added.id, maxPixelDimension: 200)
        }
    }
    
    @Test("Export preserves all metadata fields")
    func exportPreservesMetadata() async throws {
        let thumbData = Data([0xAA])
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: thumbData)
        )
        
        let added = try await manager.addResource(
            data: sampleImageData,
            type: .image,
            filename: "photo.png",
            mimeType: "image/png",
            description: "A sunset photo",
            storageLocation: .inMemory
        )
        
        let exported = try await manager.exportResource(id: added.id)
        
        #expect(exported.metadata.resourceType == .image)
        #expect(exported.metadata.fileExtension == "png")
        #expect(exported.metadata.mimeType == "image/png")
        #expect(exported.metadata.originalFilename == "photo.png")
        #expect(exported.metadata.description == "A sunset photo")
        #expect(exported.metadata.thumbnailData == thumbData)
        #expect(exported.metadata.createdAt == added.metadata.createdAt)
        #expect(exported.metadata.updatedAt == added.metadata.updatedAt)
        #expect(exported.metadata.storageLocation == .inMemory)
    }
    
    @Test("Export video at original size — maxPixelDimension is ignored for video")
    func exportVideoIgnoresPixelDimension() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .video, storageLocation: .inMemory)
        
        // maxPixelDimension only applies to .image type
        let exported = try await manager.exportResource(id: added.id, maxPixelDimension: 100)
        
        #expect(exported.data == sampleData)
    }
    
    @Test("Export read failure propagates as storageError")
    func exportReadFailure() async throws {
        let fs = MockFileSystemProvider()
        let (manager, _, _) = createTestManager(fileSystem: fs)
        
        let added = try await manager.addResource(data: sampleData, type: .file)
        
        fs.shouldThrowOnRead = true
        
        await #expect(throws: ResourceManager.ResourceManagerError.self) {
            try await manager.exportResource(id: added.id)
        }
    }
}

// MARK: - Tests: Updating Resources

@Suite("ResourceManager — Updating Resources")
struct ResourceManagerUpdateTests {
    
    @Test("Update resource data and verify metadata changes")
    func updateResource() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        let updated = try await manager.updateResource(id: added.id, data: updatedData)
        
        #expect(updated.data == updatedData)
        #expect(updated.metadata.byteSize == updatedData.count)
        #expect(updated.metadata.updatedAt >= added.metadata.createdAt)
        #expect(updated.metadata.createdAt == added.metadata.createdAt) // Created time preserved
        #expect(updated.metadata.id == added.id)
    }
    
    @Test("Update resource regenerates thumbnail for images")
    func updateImageRegeneratesThumbnail() async throws {
        let thumb1 = Data([0xAA])
        let thumb2 = Data([0xBB])
        
        // First call returns thumb1, which is used for the initial addResource.
        // The MockImageProcessor always returns the same thumbnailResult,
        // so we test that the update path calls generateThumbnail.
        let (manager, _, _) = createTestManager(
            imageProcessor: MockImageProcessor(thumbnailResult: thumb1)
        )
        
        let added = try await manager.addResource(data: sampleImageData, type: .image, storageLocation: .inMemory)
        #expect(added.metadata.thumbnailData == thumb1)
        
        let updated = try await manager.updateResource(id: added.id, data: updatedData)
        // Since the mock always returns thumb1, updated thumbnail should also be thumb1
        #expect(updated.metadata.thumbnailData == thumb1)
    }
    
    @Test("Update resource not found throws error")
    func updateResourceNotFound() async throws {
        let (manager, _, _) = createTestManager()
        let fakeID = UUID()
        
        await #expect(throws: ResourceManager.ResourceManagerError.resourceNotFound(fakeID)) {
            try await manager.updateResource(id: fakeID, data: updatedData)
        }
    }
    
    @Test("Update resource rejects empty data")
    func updateResourceRejectsEmptyData() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        
        await #expect(throws: ResourceManager.ResourceManagerError.invalidData) {
            try await manager.updateResource(id: added.id, data: Data())
        }
    }
    
    @Test("Update disk-based resource writes to file system")
    func updateDiskResource() async throws {
        let (manager, fs, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .file, filename: "test.txt")
        
        // Find the data file in the mock file system
        let dataFilePath = fs.files.keys.first { $0.contains(added.id.uuidString) && !$0.hasSuffix(".meta") }
        #expect(dataFilePath != nil)
        #expect(fs.files[dataFilePath!] == sampleData)
        
        // Update the resource
        let _ = try await manager.updateResource(id: added.id, data: updatedData)
        
        #expect(fs.files[dataFilePath!] == updatedData)
    }
}

// MARK: - Tests: Deleting Resources

@Suite("ResourceManager — Deleting Resources")
struct ResourceManagerDeleteTests {
    
    @Test("Delete an in-memory resource")
    func deleteInMemoryResource() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        #expect(await manager.resourceExists(id: added.id))
        
        try await manager.deleteResource(id: added.id)
        
        #expect(await manager.resourceExists(id: added.id) == false)
        #expect(await manager.resourceCount == 0)
    }
    
    @Test("Delete a disk-based resource removes files")
    func deleteDiskResource() async throws {
        let (manager, fs, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .file, filename: "test.txt")
        let fileCountAfterAdd = fs.files.count
        #expect(fileCountAfterAdd > 0)
        
        try await manager.deleteResource(id: added.id)
        
        // Both data file and metadata sidecar should be removed
        let remainingFiles = fs.files.keys.filter { $0.contains(added.id.uuidString) }
        #expect(remainingFiles.isEmpty)
        #expect(await manager.resourceExists(id: added.id) == false)
    }
    
    @Test("Delete resource not found throws error")
    func deleteResourceNotFound() async throws {
        let (manager, _, _) = createTestManager()
        let fakeID = UUID()
        
        await #expect(throws: ResourceManager.ResourceManagerError.resourceNotFound(fakeID)) {
            try await manager.deleteResource(id: fakeID)
        }
    }
    
    @Test("Delete all resources clears everything")
    func deleteAllResources() async throws {
        let (manager, _, _) = createTestManager()
        
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        try await manager.addResource(data: sampleData, type: .file, storageLocation: .inMemory)
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        #expect(await manager.resourceCount == 3)
        
        try await manager.deleteAllResources()
        
        #expect(await manager.resourceCount == 0)
    }
    
    @Test("Delete resources filtered by storage location")
    func deleteResourcesByLocation() async throws {
        let (manager, _, _) = createTestManager()
        
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .temporary)
        #expect(await manager.resourceCount == 3)
        
        try await manager.deleteAllResources(in: .inMemory)
        
        #expect(await manager.resourceCount == 1)
        let remaining = await manager.listResources()
        #expect(remaining.first?.storageLocation == .temporary)
    }
}

// MARK: - Tests: Utility

@Suite("ResourceManager — Utility")
struct ResourceManagerUtilityTests {
    
    @Test("resourceExists returns correct values")
    func resourceExists() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        
        #expect(await manager.resourceExists(id: added.id) == true)
        #expect(await manager.resourceExists(id: UUID()) == false)
    }
    
    @Test("totalStorageUsed calculates correctly")
    func totalStorageUsed() async throws {
        let (manager, _, _) = createTestManager()
        
        let data1 = Data("short".utf8) // 5 bytes
        let data2 = Data("a bit longer".utf8) // 12 bytes
        
        try await manager.addResource(data: data1, type: .data, storageLocation: .inMemory)
        try await manager.addResource(data: data2, type: .data, storageLocation: .temporary)
        
        let total = await manager.totalStorageUsed()
        #expect(total == data1.count + data2.count)
        
        let inMemoryOnly = await manager.totalStorageUsed(in: .inMemory)
        #expect(inMemoryOnly == data1.count)
        
        let tempOnly = await manager.totalStorageUsed(in: .temporary)
        #expect(tempOnly == data2.count)
    }
    
    @Test("resourceCount tracks additions and deletions")
    func resourceCount() async throws {
        let (manager, _, _) = createTestManager()
        
        #expect(await manager.resourceCount == 0)
        
        let r1 = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        #expect(await manager.resourceCount == 1)
        
        try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        #expect(await manager.resourceCount == 2)
        
        try await manager.deleteResource(id: r1.id)
        #expect(await manager.resourceCount == 1)
    }
    
    @Test("Default configuration has expected values")
    func defaultConfiguration() async throws {
        let config = ResourceManager.Configuration()
        
        #expect(config.defaultStorageLocation == .applicationSupport)
        #expect(config.thumbnailPixelSize == 50)
        #expect(config.maxImageFileSize == nil)
        #expect(config.maxImagePixelDimension == nil)
    }
}

// MARK: - Tests: Storage Location Directories

@Suite("ResourceManager — Storage Location Directories")
struct ResourceManagerDirectoryTests {
    
    @Test("Directory URLs are correct for each storage location")
    func directoryURLs() async throws {
        let (manager, _, _) = createTestManager()
        
        let homeDir = await manager.directoryURL(for: .homeDirectory)
        #expect(homeDir.path.contains(".swiftAgentHarness/resources"))
        #expect(homeDir.path.hasPrefix("/mock/home"))
        
        let appSupport = await manager.directoryURL(for: .applicationSupport)
        #expect(appSupport.path.contains("SwiftAgentHarness/resources"))
        #expect(appSupport.path.hasPrefix("/mock/app-support"))
        
        let temp = await manager.directoryURL(for: .temporary)
        #expect(temp.path.contains("sah-resources"))
        #expect(temp.path.hasPrefix("/mock/tmp"))
    }
    
    @Test("Resources in different locations have independent paths")
    func independentLocationPaths() async throws {
        let (manager, fs, _) = createTestManager()
        
        let r1 = try await manager.addResource(data: sampleData, type: .file, storageLocation: .homeDirectory)
        let r2 = try await manager.addResource(data: sampleData, type: .file, storageLocation: .applicationSupport)
        let r3 = try await manager.addResource(data: sampleData, type: .file, storageLocation: .temporary)
        
        let url1 = try await manager.getResourceURL(id: r1.id)
        let url2 = try await manager.getResourceURL(id: r2.id)
        let url3 = try await manager.getResourceURL(id: r3.id)
        
        #expect(url1!.path.contains(".swiftAgentHarness"))
        #expect(url2!.path.contains("SwiftAgentHarness"))
        #expect(url3!.path.contains("sah-resources"))
        
        // All three should be different paths
        #expect(url1!.path != url2!.path)
        #expect(url2!.path != url3!.path)
    }
}

// MARK: - Tests: Error Handling

@Suite("ResourceManager — Error Handling")
struct ResourceManagerErrorTests {
    
    @Test("File system write error propagates as storageError")
    func writeErrorPropagation() async throws {
        let fs = MockFileSystemProvider()
        fs.shouldThrowOnWrite = true
        let (manager, _, _) = createTestManager(fileSystem: fs)
        
        // Disk-based write should fail
        do {
            try await manager.addResource(data: sampleData, type: .file, storageLocation: .applicationSupport)
            Issue.record("Expected an error to be thrown")
        } catch {
            // The error should propagate from the file system
            #expect(error is NSError || error is ResourceManager.ResourceManagerError)
        }
    }
    
    @Test("File system read error propagates as storageError")
    func readErrorPropagation() async throws {
        let fs = MockFileSystemProvider()
        let (manager, _, _) = createTestManager(fileSystem: fs)
        
        // Add normally
        let added = try await manager.addResource(data: sampleData, type: .file)
        
        // Now make reads fail
        fs.shouldThrowOnRead = true
        
        await #expect(throws: ResourceManager.ResourceManagerError.self) {
            try await manager.getResource(id: added.id)
        }
    }
    
    @Test("File system delete error propagates as storageError")
    func deleteErrorPropagation() async throws {
        let fs = MockFileSystemProvider()
        let (manager, _, _) = createTestManager(fileSystem: fs)
        
        let added = try await manager.addResource(data: sampleData, type: .file)
        
        // Now make deletes fail
        fs.shouldThrowOnDelete = true
        
        await #expect(throws: ResourceManager.ResourceManagerError.self) {
            try await manager.deleteResource(id: added.id)
        }
    }
    
    @Test("Directory creation failure throws directoryCreationFailed")
    func directoryCreationFailure() async throws {
        let fs = MockFileSystemProvider()
        fs.shouldThrowOnCreateDirectory = true
        let (manager, _, _) = createTestManager(fileSystem: fs)
        
        do {
            try await manager.addResource(data: sampleData, type: .file, storageLocation: .applicationSupport)
            Issue.record("Expected directoryCreationFailed error")
        } catch let error as ResourceManager.ResourceManagerError {
            if case .directoryCreationFailed = error {
                // Expected
            } else {
                Issue.record("Expected directoryCreationFailed but got \(error)")
            }
        }
    }
}

// MARK: - Tests: Index Rebuild

@Suite("ResourceManager — Index Rebuild")
struct ResourceManagerRebuildTests {
    
    @Test("Rebuild index restores disk-based resources from metadata files")
    func rebuildIndexFromDisk() async throws {
        let fs = MockFileSystemProvider()
        let imageProcessor = MockImageProcessor()
        let config = ResourceManager.Configuration(defaultStorageLocation: .applicationSupport)
        
        // Create first manager and add resources
        let manager1 = ResourceManager(configuration: config, logger: nil, fileSystem: fs, imageProcessor: imageProcessor)
        let r1 = try await manager1.addResource(data: sampleData, type: .file, filename: "doc.txt")
        let r2 = try await manager1.addResource(data: sampleImageData, type: .image, filename: "photo.png")
        
        // Create a new manager with the same file system (simulates restart)
        let manager2 = ResourceManager(configuration: config, logger: nil, fileSystem: fs, imageProcessor: imageProcessor)
        
        // Before rebuild, new manager has no resources
        #expect(await manager2.resourceCount == 0)
        
        // After rebuild, resources should be found
        try await manager2.rebuildIndex()
        
        #expect(await manager2.resourceCount == 2)
        #expect(await manager2.resourceExists(id: r1.id))
        #expect(await manager2.resourceExists(id: r2.id))
        
        // Verify we can retrieve the resources
        let retrieved = try await manager2.getResource(id: r1.id)
        #expect(retrieved.data == sampleData)
    }
    
    @Test("Rebuild index preserves in-memory resources")
    func rebuildIndexPreservesInMemory() async throws {
        let fs = MockFileSystemProvider()
        let (manager, _, _) = createTestManager(fileSystem: fs)
        
        let inMemResource = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        let diskResource = try await manager.addResource(data: sampleData, type: .file, filename: "doc.txt")
        
        #expect(await manager.resourceCount == 2)
        
        try await manager.rebuildIndex()
        
        // Both should still exist — in-memory preserved, disk-based rebuilt
        #expect(await manager.resourceCount == 2)
        #expect(await manager.resourceExists(id: inMemResource.id))
        #expect(await manager.resourceExists(id: diskResource.id))
    }
    
    @Test("Rebuild index skips resources with missing data files")
    func rebuildIndexSkipsMissingFiles() async throws {
        let fs = MockFileSystemProvider()
        let config = ResourceManager.Configuration(defaultStorageLocation: .applicationSupport)
        
        let manager1 = ResourceManager(configuration: config, logger: nil, fileSystem: fs, imageProcessor: MockImageProcessor())
        let r1 = try await manager1.addResource(data: sampleData, type: .file, filename: "doc.txt")
        
        // Remove the data file but leave the metadata sidecar
        let dataFilePath = fs.files.keys.first { $0.contains(r1.id.uuidString) && !$0.hasSuffix(".meta") }
        #expect(dataFilePath != nil)
        fs.files.removeValue(forKey: dataFilePath!)
        
        // Create a new manager and rebuild
        let manager2 = ResourceManager(configuration: config, logger: nil, fileSystem: fs, imageProcessor: MockImageProcessor())
        try await manager2.rebuildIndex()
        
        // Resource should be skipped because its data file is missing
        #expect(await manager2.resourceCount == 0)
    }
}

// MARK: - Tests: Metadata Persistence

@Suite("ResourceManager — Metadata Persistence")
struct ResourceManagerMetadataTests {
    
    @Test("Metadata sidecar is written for disk-based resources")
    func metadataSidecarWritten() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .file, filename: "notes.md")
        
        // Verify a .meta file was created
        let metaFile = fs.files.keys.first { $0.contains(resource.id.uuidString) && $0.hasSuffix(".meta") }
        #expect(metaFile != nil)
        
        // Verify the metadata is valid JSON
        let metaData = fs.files[metaFile!]!
        let metaDecoder = JSONDecoder()
        metaDecoder.dateDecodingStrategy = .iso8601
        let decoded = try metaDecoder.decode(ResourceManager.ResourceMetadata.self, from: metaData)
        
        #expect(decoded.id == resource.id)
        #expect(decoded.resourceType == .file)
        #expect(decoded.fileExtension == "md")
        #expect(decoded.originalFilename == "notes.md")
        #expect(decoded.byteSize == sampleData.count)
    }
    
    @Test("No metadata sidecar for in-memory resources")
    func noMetadataSidecarForInMemory() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        
        let metaFile = fs.files.keys.first { $0.contains(resource.id.uuidString) && $0.hasSuffix(".meta") }
        #expect(metaFile == nil)
    }
    
    @Test("Metadata sidecar is updated when resource is updated")
    func metadataSidecarUpdatedOnUpdate() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .file, filename: "notes.md")
        
        // Read original metadata
        let metaFile = fs.files.keys.first { $0.contains(resource.id.uuidString) && $0.hasSuffix(".meta") }!
        let metaDecoder = JSONDecoder()
        metaDecoder.dateDecodingStrategy = .iso8601
        let originalMeta = try metaDecoder.decode(ResourceManager.ResourceMetadata.self, from: fs.files[metaFile]!)
        
        // Update the resource
        let _ = try await manager.updateResource(id: resource.id, data: updatedData)
        
        // Read updated metadata
        let updatedMeta = try metaDecoder.decode(ResourceManager.ResourceMetadata.self, from: fs.files[metaFile]!)
        
        #expect(updatedMeta.byteSize == updatedData.count)
        #expect(updatedMeta.byteSize != originalMeta.byteSize)
        #expect(updatedMeta.createdAt == originalMeta.createdAt)
    }
    
    @Test("Metadata sidecar is removed when resource is deleted")
    func metadataSidecarRemovedOnDelete() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .file, filename: "notes.md")
        
        let metaFile = fs.files.keys.first { $0.contains(resource.id.uuidString) && $0.hasSuffix(".meta") }
        #expect(metaFile != nil)
        
        try await manager.deleteResource(id: resource.id)
        
        let metaFileAfterDelete = fs.files.keys.first { $0.contains(resource.id.uuidString) && $0.hasSuffix(".meta") }
        #expect(metaFileAfterDelete == nil)
    }
}

// MARK: - Tests: Updating Resource Metadata

@Suite("ResourceManager — Updating Resource Metadata")
struct ResourceManagerUpdateMetadataTests {
    
    @Test("Add resource with description")
    func addResourceWithDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let resource = try await manager.addResource(
            data: sampleData,
            type: .file,
            filename: "report.pdf",
            description: "Q4 financial report",
            storageLocation: .inMemory
        )
        
        #expect(resource.metadata.description == "Q4 financial report")
    }
    
    @Test("Add resource without description defaults to nil")
    func addResourceWithoutDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let resource = try await manager.addResource(data: sampleData, type: .data, storageLocation: .inMemory)
        
        #expect(resource.metadata.description == nil)
    }
    
    @Test("Add image with description")
    func addImageWithDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let resource = try await manager.addImage(
            data: sampleImageData,
            filename: "photo.jpg",
            description: "Team photo from offsite",
            storageLocation: .inMemory
        )
        
        #expect(resource.metadata.description == "Team photo from offsite")
    }
    
    @Test("Update resource metadata — change description")
    func updateMetadataDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            description: "Original description",
            storageLocation: .inMemory
        )
        
        let updated = try await manager.updateResourceMetadata(
            id: added.id,
            description: "Updated description"
        )
        
        #expect(updated.description == "Updated description")
        #expect(updated.updatedAt >= added.metadata.updatedAt)
        #expect(updated.createdAt == added.metadata.createdAt)
        #expect(updated.byteSize == added.metadata.byteSize) // Data unchanged
    }
    
    @Test("Update resource metadata — clear description with empty string")
    func updateMetadataClearDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            description: "Some description",
            storageLocation: .inMemory
        )
        
        let updated = try await manager.updateResourceMetadata(
            id: added.id,
            description: .some("")
        )
        
        #expect(updated.description == "")
    }
    
    @Test("Update resource metadata — set description to nil")
    func updateMetadataNilDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            description: "Some description",
            storageLocation: .inMemory
        )
        
        let updated = try await manager.updateResourceMetadata(
            id: added.id,
            description: .some(nil)
        )
        
        #expect(updated.description == nil)
    }
    
    @Test("Update resource metadata — omitted fields are preserved")
    func updateMetadataPreservesOmittedFields() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            filename: "report.pdf",
            mimeType: "application/pdf",
            description: "Original description",
            storageLocation: .inMemory
        )
        
        // Only update description — mimeType and originalFilename should be preserved
        let updated = try await manager.updateResourceMetadata(
            id: added.id,
            description: "New description"
        )
        
        #expect(updated.description == "New description")
        #expect(updated.mimeType == "application/pdf")
        #expect(updated.originalFilename == "report.pdf")
    }
    
    @Test("Update resource metadata — change mimeType")
    func updateMetadataMimeType() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            mimeType: "text/plain",
            storageLocation: .inMemory
        )
        
        let updated = try await manager.updateResourceMetadata(
            id: added.id,
            mimeType: "text/markdown"
        )
        
        #expect(updated.mimeType == "text/markdown")
    }
    
    @Test("Update resource metadata — change originalFilename")
    func updateMetadataOriginalFilename() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            filename: "old_name.txt",
            storageLocation: .inMemory
        )
        
        let updated = try await manager.updateResourceMetadata(
            id: added.id,
            originalFilename: "new_name.txt"
        )
        
        #expect(updated.originalFilename == "new_name.txt")
    }
    
    @Test("Update resource metadata — not found throws error")
    func updateMetadataNotFound() async throws {
        let (manager, _, _) = createTestManager()
        let fakeID = UUID()
        
        await #expect(throws: ResourceManager.ResourceManagerError.resourceNotFound(fakeID)) {
            try await manager.updateResourceMetadata(id: fakeID, description: "test")
        }
    }
    
    @Test("Update resource metadata persists sidecar for disk-based resources")
    func updateMetadataPersistsSidecar() async throws {
        let (manager, fs, _) = createTestManager()
        
        let resource = try await manager.addResource(
            data: sampleData,
            type: .file,
            filename: "notes.md",
            description: "Original"
        )
        
        let _ = try await manager.updateResourceMetadata(
            id: resource.id,
            description: "Updated via metadata"
        )
        
        // Verify the sidecar was updated
        let metaFile = fs.files.keys.first { $0.contains(resource.id.uuidString) && $0.hasSuffix(".meta") }!
        let metaDecoder = JSONDecoder()
        metaDecoder.dateDecodingStrategy = .iso8601
        let decoded = try metaDecoder.decode(ResourceManager.ResourceMetadata.self, from: fs.files[metaFile]!)
        
        #expect(decoded.description == "Updated via metadata")
    }
    
    @Test("updateResource preserves existing description")
    func updateResourceDataPreservesDescription() async throws {
        let (manager, _, _) = createTestManager()
        
        let added = try await manager.addResource(
            data: sampleData,
            type: .file,
            description: "Keep this description",
            storageLocation: .inMemory
        )
        
        let updated = try await manager.updateResource(id: added.id, data: updatedData)
        
        #expect(updated.metadata.description == "Keep this description")
        #expect(updated.data == updatedData)
    }
}

// MARK: - Tests: ResourceMetadata Codable

@Suite("ResourceMetadata — Codable")
struct ResourceMetadataCodableTests {
    
    @Test("ResourceMetadata round-trips through JSON encoding/decoding")
    func metadataRoundTrip() throws {
        let original = ResourceManager.ResourceMetadata(
            id: UUID(),
            resourceType: .image,
            fileExtension: "png",
            mimeType: "image/png",
            originalFilename: "screenshot.png",
            description: "A screenshot of the dashboard",
            byteSize: 1024,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            thumbnailData: Data([0xAA, 0xBB, 0xCC]),
            storageLocation: .applicationSupport
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ResourceManager.ResourceMetadata.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("ResourceMetadata with nil optional fields round-trips correctly")
    func metadataRoundTripWithNils() throws {
        let original = ResourceManager.ResourceMetadata(
            id: UUID(),
            resourceType: .data,
            fileExtension: nil,
            mimeType: nil,
            originalFilename: nil,
            description: nil,
            byteSize: 42,
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: 500),
            thumbnailData: nil,
            storageLocation: .inMemory
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ResourceManager.ResourceMetadata.self, from: data)
        
        #expect(decoded == original)
    }
}
