import Foundation
import Logging
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// MARK: - File System Abstraction

/// Protocol abstracting file system operations for testability
protocol FileSystemProviding: Sendable {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws
    func fileExists(atPath path: String) -> Bool
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func read(from url: URL) throws -> Data
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL]
    var homeDirectoryForCurrentUser: URL { get }
    var applicationSupportDirectory: URL { get }
    var temporaryDirectory: URL { get }
}

/// Default file system provider backed by `FileManager`
struct DefaultFileSystemProvider: FileSystemProviding {
    
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }
    
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }
    
    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
    
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
    }
    
    var homeDirectoryForCurrentUser: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
    
    var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }
    
    var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }
}

// MARK: - Image Processing Abstraction

/// Protocol abstracting image operations for testability.
///
/// All pixel-based scaling operations preserve the original aspect ratio.
/// The image is scaled so its longest edge fits within the specified dimension.
protocol ImageProcessing: Sendable {
    /// Generate a thumbnail whose longest edge is at most `maxPixelSize` pixels. Aspect ratio is preserved.
    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data?
    /// Scale an image so its longest edge is at most `maxPixelDimension` pixels. Aspect ratio is preserved.
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data?
    /// Scale an image to fit within the specified maximum file size in bytes. Aspect ratio is preserved.
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data?
}

#if canImport(CoreGraphics) && canImport(ImageIO)
/// Default image processor using CoreGraphics and ImageIO
struct DefaultImageProcessor: ImageProcessing {
    
    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        return jpegData(from: thumbnail, quality: 0.7)
    }
    
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        
        guard let scaledImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        // Attempt to preserve the original format
        if let utType = CGImageSourceGetType(source),
           let result = imageData(from: scaledImage, type: utType, quality: 0.85) {
            return result
        }
        
        return jpegData(from: scaledImage, quality: 0.85)
    }
    
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? {
        guard data.count > maxFileSize else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        
        // Get original dimensions
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        
        // First try reducing JPEG quality at full resolution
        if let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            for quality in stride(from: 0.8, through: 0.1, by: -0.1) {
                if let compressed = jpegData(from: fullImage, quality: quality),
                   compressed.count <= maxFileSize {
                    return compressed
                }
            }
        }
        
        // If quality reduction isn't enough, binary search for the right pixel dimension
        var low = 1
        var high = max(width, height)
        var bestData: Data?
        
        while low <= high {
            let mid = (low + high) / 2
            
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: mid,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            
            guard let scaledImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                high = mid - 1
                continue
            }
            
            if let scaledData = jpegData(from: scaledImage, quality: 0.8) {
                if scaledData.count <= maxFileSize {
                    bestData = scaledData
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            } else {
                high = mid - 1
            }
        }
        
        return bestData
    }
    
    // MARK: - Private Helpers
    
    private func jpegData(from image: CGImage, quality: Double) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
    
    private func imageData(from image: CGImage, type: CFString, quality: Double) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            type,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
#else
/// Fallback image processor when CoreGraphics/ImageIO are not available
struct DefaultImageProcessor: ImageProcessing {
    func generateThumbnail(from data: Data, maxPixelSize: Int) -> Data? { nil }
    func scaleImage(_ data: Data, maxPixelDimension: Int) -> Data? { nil }
    func scaleImageToFileSize(_ data: Data, maxFileSize: Int) -> Data? { data.count <= maxFileSize ? data : nil }
}
#endif

// MARK: - ResourceManager

/// The `ResourceManager` handles image, video, file, and data resources.
/// It manages where and how to store them and provides convenience functions for retrieving them.
///
/// ## Storage Locations
/// - **Home Directory**: `~/.swiftAgentHarness/resources/`
/// - **Application Support**: `~/Library/Application Support/SwiftAgentHarness/resources/`
/// - **Temporary**: `{tmp}/sah-resources/`
/// - **In-Memory**: No disk persistence; data lives only in the actor's memory
///
/// Each resource can be stored in a different location. The `ResourceManager` can be configured with a default
/// location, but the location can be overridden per-resource when adding.
///
/// ## Metadata
/// Every resource carries metadata: unique ID, description, creation time, update time, file type, MIME type,
/// and byte size. For images and videos, a 50px x 50px JPEG thumbnail is automatically generated.
///
/// ## Image Processing
/// When images are added, there are additional options to scale the image to fit within a maximum file size
/// (in bytes) or a maximum pixel dimension. These can be set globally via `Configuration` or per-image
/// via `addImage(...)` overrides.
public actor ResourceManager {
    
    // MARK: - Error Types
    
    enum ResourceManagerError: Error, Equatable {
        case resourceNotFound(UUID)
        case invalidData
        case storageError(String)
        case thumbnailGenerationFailed
        case imageScalingFailed
        case directoryCreationFailed(String)
    }
    
    // MARK: - Supporting Types
    
    /// Where a resource should be persisted
    public enum StorageLocation: String, Sendable, Codable, Equatable {
        case homeDirectory
        case applicationSupport
        case temporary
        case inMemory
    }
    
    /// The kind of content a resource holds
    enum ResourceType: String, Sendable, Codable, Equatable {
        case image
        case video
        case file
        case data
    }
    
    /// Metadata associated with a managed resource
    struct ResourceMetadata: Sendable, Identifiable, Equatable, Codable {
        let id: UUID
        let resourceType: ResourceType
        let fileExtension: String?
        let mimeType: String?
        let originalFilename: String?
        let description: String?
        let byteSize: Int
        let createdAt: Date
        let updatedAt: Date
        let thumbnailData: Data?
        let storageLocation: StorageLocation
    }
    
    /// A managed resource containing its metadata and raw data
    struct Resource: Sendable, Identifiable {
        let id: UUID
        let metadata: ResourceMetadata
        let data: Data
    }
    
    /// Configuration controlling default behaviors of the `ResourceManager`
    public struct Configuration: Sendable {
        /// Default storage location for new resources when none is specified
        public var defaultStorageLocation: StorageLocation
        /// Pixel dimension of auto-generated thumbnails (square)
        public var thumbnailPixelSize: Int
        /// Global maximum file size (bytes) for image resources. `nil` means no limit.
        public var maxImageFileSize: Int?
        /// Global maximum pixel dimension for image resources. `nil` means no limit.
        public var maxImagePixelDimension: Int?
        
        public init(
            defaultStorageLocation: StorageLocation = .applicationSupport,
            thumbnailPixelSize: Int = 50,
            maxImageFileSize: Int? = nil,
            maxImagePixelDimension: Int? = nil
        ) {
            self.defaultStorageLocation = defaultStorageLocation
            self.thumbnailPixelSize = thumbnailPixelSize
            self.maxImageFileSize = maxImageFileSize
            self.maxImagePixelDimension = maxImagePixelDimension
        }
    }
    
    // MARK: - Properties
    
    let configuration: Configuration
    private let logger: Logger?
    private let fileSystem: FileSystemProviding
    private let imageProcessor: ImageProcessing
    
    /// In-memory index of all managed resource metadata, keyed by resource ID
    private var resourceIndex: [UUID: ResourceMetadata] = [:]
    /// Data store for resources using `.inMemory` storage
    private var inMemoryStore: [UUID: Data] = [:]
    
    // MARK: - Initialization
    
    public init(
        configuration: Configuration = .init(),
        logger: Logger? = nil
    ) {
        self.init(
            configuration: configuration,
            logger: logger,
            fileSystem: DefaultFileSystemProvider(),
            imageProcessor: DefaultImageProcessor()
        )
    }

    init(
        configuration: Configuration = .init(),
        logger: Logger? = nil,
        fileSystem: FileSystemProviding,
        imageProcessor: ImageProcessing
    ) {
        self.configuration = configuration
        self.logger = logger
        self.fileSystem = fileSystem
        self.imageProcessor = imageProcessor
    }
    
    // MARK: - Public API: Adding Resources
    
    /// Add a resource with raw data.
    ///
    /// Thumbnails are automatically generated for `.image` and `.video` types.
    /// Global image scaling configuration is applied when the type is `.image`.
    ///
    /// - Parameters:
    ///   - data: The raw resource data. Must not be empty.
    ///   - type: The kind of resource (image, video, file, data).
    ///   - filename: Optional original filename (used to extract file extension).
    ///   - mimeType: Optional MIME type string.
    ///   - description: Optional human-readable description of the resource.
    ///   - storageLocation: Override for the default storage location.
    /// - Returns: The newly created `Resource`.
    @discardableResult
    func addResource(
        data: Data,
        type: ResourceType,
        filename: String? = nil,
        mimeType: String? = nil,
        description: String? = nil,
        storageLocation: StorageLocation? = nil
    ) throws -> Resource {
        guard !data.isEmpty else {
            throw ResourceManagerError.invalidData
        }
        
        let id = UUID()
        let location = storageLocation ?? configuration.defaultStorageLocation
        let fileExtension = filename.flatMap { extractFileExtension(from: $0) }
        let now = Date()
        
        // Generate thumbnail for images and videos
        var thumbnailData: Data?
        if type == .image || type == .video {
            thumbnailData = imageProcessor.generateThumbnail(from: data, maxPixelSize: configuration.thumbnailPixelSize)
            if thumbnailData == nil {
                logger?.warning("[ResourceManager] Failed to generate thumbnail for resource \(id)")
            }
        }
        
        // Apply global image scaling configuration
        var processedData = data
        if type == .image {
            if let maxDimension = configuration.maxImagePixelDimension {
                if let scaled = imageProcessor.scaleImage(processedData, maxPixelDimension: maxDimension) {
                    processedData = scaled
                } else {
                    logger?.warning("[ResourceManager] Failed to scale image \(id) to max dimension \(maxDimension)")
                }
            }
            if let maxFileSize = configuration.maxImageFileSize {
                if let scaled = imageProcessor.scaleImageToFileSize(processedData, maxFileSize: maxFileSize) {
                    processedData = scaled
                } else {
                    logger?.warning("[ResourceManager] Failed to scale image \(id) to max file size \(maxFileSize)")
                }
            }
        }
        
        // Persist the data
        if location == .inMemory {
            inMemoryStore[id] = processedData
        } else {
            let fileURL = urlForResource(id: id, fileExtension: fileExtension, storageLocation: location)
            try ensureDirectoryExists(for: location)
            try fileSystem.write(processedData, to: fileURL, options: .atomic)
            logger?.info("[ResourceManager] Stored resource \(id) at \(fileURL.path)")
        }
        
        // Build and persist metadata
        let metadata = ResourceMetadata(
            id: id,
            resourceType: type,
            fileExtension: fileExtension,
            mimeType: mimeType,
            originalFilename: filename,
            description: description,
            byteSize: processedData.count,
            createdAt: now,
            updatedAt: now,
            thumbnailData: thumbnailData,
            storageLocation: location
        )
        
        if location != .inMemory {
            try saveMetadataSidecar(metadata)
        }
        
        resourceIndex[id] = metadata
        
        logger?.info("[ResourceManager] Added resource \(id) (type: \(type.rawValue), size: \(processedData.count) bytes, location: \(location.rawValue))")
        
        return Resource(id: id, metadata: metadata, data: processedData)
    }
    
    /// Add an image resource with per-image scaling overrides.
    ///
    /// This convenience method generates a thumbnail, applies dimension/file-size scaling,
    /// and stores the processed image.
    ///
    /// - Parameters:
    ///   - data: The raw image data. Must not be empty.
    ///   - filename: Optional original filename.
    ///   - mimeType: Optional MIME type. Defaults to `image/jpeg` if not provided.
    ///   - description: Optional human-readable description of the image.
    ///   - maxFileSize: Override maximum file size in bytes (takes priority over global config).
    ///   - maxPixelDimension: Override maximum pixel dimension (takes priority over global config).
    ///   - storageLocation: Override for the default storage location.
    /// - Returns: The newly created `Resource`.
    @discardableResult
    func addImage(
        data: Data,
        filename: String? = nil,
        mimeType: String? = nil,
        description: String? = nil,
        maxFileSize: Int? = nil,
        maxPixelDimension: Int? = nil,
        storageLocation: StorageLocation? = nil
    ) throws -> Resource {
        guard !data.isEmpty else {
            throw ResourceManagerError.invalidData
        }
        
        let id = UUID()
        let location = storageLocation ?? configuration.defaultStorageLocation
        let fileExtension = filename.flatMap { extractFileExtension(from: $0) } ?? "jpg"
        let now = Date()
        
        // Generate thumbnail
        let thumbnailData = imageProcessor.generateThumbnail(from: data, maxPixelSize: configuration.thumbnailPixelSize)
        if thumbnailData == nil {
            logger?.warning("[ResourceManager] Failed to generate thumbnail for image \(id)")
        }
        
        // Apply scaling — per-image overrides take priority over global config
        var processedData = data
        if let maxDimension = maxPixelDimension ?? configuration.maxImagePixelDimension {
            if let scaled = imageProcessor.scaleImage(processedData, maxPixelDimension: maxDimension) {
                processedData = scaled
            } else {
                logger?.warning("[ResourceManager] Failed to scale image \(id) to max dimension \(maxDimension)")
            }
        }
        if let maxSize = maxFileSize ?? configuration.maxImageFileSize {
            if let scaled = imageProcessor.scaleImageToFileSize(processedData, maxFileSize: maxSize) {
                processedData = scaled
            } else {
                logger?.warning("[ResourceManager] Failed to scale image \(id) to max file size \(maxSize)")
            }
        }
        
        // Persist the data
        if location == .inMemory {
            inMemoryStore[id] = processedData
        } else {
            let fileURL = urlForResource(id: id, fileExtension: fileExtension, storageLocation: location)
            try ensureDirectoryExists(for: location)
            try fileSystem.write(processedData, to: fileURL, options: .atomic)
            logger?.info("[ResourceManager] Stored image \(id) at \(fileURL.path)")
        }
        
        // Build and persist metadata
        let metadata = ResourceMetadata(
            id: id,
            resourceType: .image,
            fileExtension: fileExtension,
            mimeType: mimeType ?? "image/jpeg",
            originalFilename: filename,
            description: description,
            byteSize: processedData.count,
            createdAt: now,
            updatedAt: now,
            thumbnailData: thumbnailData,
            storageLocation: location
        )
        
        if location != .inMemory {
            try saveMetadataSidecar(metadata)
        }
        
        resourceIndex[id] = metadata
        
        logger?.info("[ResourceManager] Added image \(id) (size: \(processedData.count) bytes, location: \(location.rawValue))")
        
        return Resource(id: id, metadata: metadata, data: processedData)
    }
    
    // MARK: - Public API: Retrieving Resources
    
    /// Retrieve a resource by ID, loading its data from disk if necessary.
    ///
    /// - Parameter id: The unique identifier of the resource.
    /// - Returns: The `Resource` including its data.
    func getResource(id: UUID) throws -> Resource {
        guard let metadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        
        let data: Data
        if metadata.storageLocation == .inMemory {
            guard let storedData = inMemoryStore[id] else {
                throw ResourceManagerError.resourceNotFound(id)
            }
            data = storedData
        } else {
            let fileURL = urlForResource(id: id, fileExtension: metadata.fileExtension, storageLocation: metadata.storageLocation)
            do {
                data = try fileSystem.read(from: fileURL)
            } catch {
                logger?.error("[ResourceManager] Failed to read resource \(id) from \(fileURL.path): \(error)")
                throw ResourceManagerError.storageError("Failed to read resource: \(error.localizedDescription)")
            }
        }
        
        return Resource(id: id, metadata: metadata, data: data)
    }
    
    /// Retrieve only the metadata for a resource (does not load data from disk).
    func getResourceMetadata(id: UUID) throws -> ResourceMetadata {
        guard let metadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        return metadata
    }
    
    /// Retrieve the thumbnail data for an image or video resource.
    func getThumbnail(id: UUID) throws -> Data {
        guard let metadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        guard let thumbnailData = metadata.thumbnailData else {
            throw ResourceManagerError.thumbnailGenerationFailed
        }
        return thumbnailData
    }
    
    /// Get the on-disk file URL for a resource. Returns `nil` for in-memory resources.
    func getResourceURL(id: UUID) throws -> URL? {
        guard let metadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        guard metadata.storageLocation != .inMemory else {
            return nil
        }
        return urlForResource(id: id, fileExtension: metadata.fileExtension, storageLocation: metadata.storageLocation)
    }
    
    /// List metadata for all resources, optionally filtered by type.
    func listResources(ofType type: ResourceType? = nil) -> [ResourceMetadata] {
        let allMetadata = Array(resourceIndex.values)
        if let type {
            return allMetadata.filter { $0.resourceType == type }
        }
        return allMetadata
    }
    
    // MARK: - Public API: Exporting Resources
    
    /// Export a copy of a resource, optionally scaling image data to a target pixel size.
    ///
    /// The original resource is **not** modified. A new `Resource` value is returned containing
    /// a copy of the data (scaled if applicable) and metadata reflecting the exported content.
    ///
    /// For image resources, if `maxPixelDimension` is provided the exported copy is scaled so
    /// its longest edge fits within that dimension. **Aspect ratio is always preserved.**
    /// Non-image resources ignore the `maxPixelDimension` parameter and return the data as-is.
    ///
    /// - Parameters:
    ///   - id: The unique identifier of the resource to export.
    ///   - maxPixelDimension: For images, the maximum pixel dimension for the longest edge.
    ///     Pass `nil` to export at original size.
    /// - Returns: A `Resource` containing the exported data and metadata.
    func exportResource(id: UUID, maxPixelDimension: Int? = nil) throws -> Resource {
        guard let metadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        
        // Load the original data
        let originalData: Data
        if metadata.storageLocation == .inMemory {
            guard let storedData = inMemoryStore[id] else {
                throw ResourceManagerError.resourceNotFound(id)
            }
            originalData = storedData
        } else {
            let fileURL = urlForResource(id: id, fileExtension: metadata.fileExtension, storageLocation: metadata.storageLocation)
            do {
                originalData = try fileSystem.read(from: fileURL)
            } catch {
                logger?.error("[ResourceManager] Failed to read resource \(id) for export: \(error)")
                throw ResourceManagerError.storageError("Failed to read resource for export: \(error.localizedDescription)")
            }
        }
        
        // Scale the data if this is an image and a target dimension was requested
        var exportedData = originalData
        if metadata.resourceType == .image, let maxDimension = maxPixelDimension {
            if let scaled = imageProcessor.scaleImage(originalData, maxPixelDimension: maxDimension) {
                exportedData = scaled
            } else {
                logger?.warning("[ResourceManager] Failed to scale image \(id) to \(maxDimension)px for export")
                throw ResourceManagerError.imageScalingFailed
            }
        }
        
        // Build export metadata reflecting the (possibly different) byte size
        let exportMetadata = ResourceMetadata(
            id: metadata.id,
            resourceType: metadata.resourceType,
            fileExtension: metadata.fileExtension,
            mimeType: metadata.mimeType,
            originalFilename: metadata.originalFilename,
            description: metadata.description,
            byteSize: exportedData.count,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            thumbnailData: metadata.thumbnailData,
            storageLocation: metadata.storageLocation
        )
        
        logger?.info("[ResourceManager] Exported resource \(id) (\(exportedData.count) bytes)")
        
        return Resource(id: id, metadata: exportMetadata, data: exportedData)
    }
    
    // MARK: - Public API: Updating Resources
    
    /// Replace the data for an existing resource.
    ///
    /// Metadata timestamps and byte size are updated. Thumbnails are regenerated for image/video resources.
    @discardableResult
    func updateResource(id: UUID, data: Data) throws -> Resource {
        guard let existingMetadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        guard !data.isEmpty else {
            throw ResourceManagerError.invalidData
        }
        
        let now = Date()
        
        // Regenerate thumbnail if applicable
        var thumbnailData = existingMetadata.thumbnailData
        if existingMetadata.resourceType == .image || existingMetadata.resourceType == .video {
            if let newThumb = imageProcessor.generateThumbnail(from: data, maxPixelSize: configuration.thumbnailPixelSize) {
                thumbnailData = newThumb
            }
        }
        
        // Persist updated data
        if existingMetadata.storageLocation == .inMemory {
            inMemoryStore[id] = data
        } else {
            let fileURL = urlForResource(id: id, fileExtension: existingMetadata.fileExtension, storageLocation: existingMetadata.storageLocation)
            try fileSystem.write(data, to: fileURL, options: .atomic)
        }
        
        // Build updated metadata
        let updatedMetadata = ResourceMetadata(
            id: existingMetadata.id,
            resourceType: existingMetadata.resourceType,
            fileExtension: existingMetadata.fileExtension,
            mimeType: existingMetadata.mimeType,
            originalFilename: existingMetadata.originalFilename,
            description: existingMetadata.description,
            byteSize: data.count,
            createdAt: existingMetadata.createdAt,
            updatedAt: now,
            thumbnailData: thumbnailData,
            storageLocation: existingMetadata.storageLocation
        )
        
        if existingMetadata.storageLocation != .inMemory {
            try saveMetadataSidecar(updatedMetadata)
        }
        
        resourceIndex[id] = updatedMetadata
        
        logger?.info("[ResourceManager] Updated resource \(id) (new size: \(data.count) bytes)")
        
        return Resource(id: id, metadata: updatedMetadata, data: data)
    }
    
    /// Update the metadata fields on an existing resource without changing its data.
    ///
    /// Only non-nil parameters are applied; pass `nil` to leave a field unchanged.
    /// The `updatedAt` timestamp is always refreshed.
    ///
    /// - Parameters:
    ///   - id: The unique identifier of the resource to update.
    ///   - description: New description, or `nil` to keep existing. Pass `""` to clear.
    ///   - mimeType: New MIME type, or `nil` to keep existing.
    ///   - originalFilename: New original filename, or `nil` to keep existing.
    /// - Returns: The updated `ResourceMetadata`.
    @discardableResult
    func updateResourceMetadata(
        id: UUID,
        description: String?? = nil,
        mimeType: String?? = nil,
        originalFilename: String?? = nil
    ) throws -> ResourceMetadata {
        guard let existingMetadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        
        let now = Date()
        
        let updatedMetadata = ResourceMetadata(
            id: existingMetadata.id,
            resourceType: existingMetadata.resourceType,
            fileExtension: existingMetadata.fileExtension,
            mimeType: mimeType ?? existingMetadata.mimeType,
            originalFilename: originalFilename ?? existingMetadata.originalFilename,
            description: description ?? existingMetadata.description,
            byteSize: existingMetadata.byteSize,
            createdAt: existingMetadata.createdAt,
            updatedAt: now,
            thumbnailData: existingMetadata.thumbnailData,
            storageLocation: existingMetadata.storageLocation
        )
        
        if existingMetadata.storageLocation != .inMemory {
            try saveMetadataSidecar(updatedMetadata)
        }
        
        resourceIndex[id] = updatedMetadata
        
        logger?.info("[ResourceManager] Updated metadata for resource \(id)")
        
        return updatedMetadata
    }
    
    // MARK: - Public API: Deleting Resources
    
    /// Delete a resource by ID, removing both its data and metadata from disk.
    func deleteResource(id: UUID) throws {
        guard let metadata = resourceIndex[id] else {
            throw ResourceManagerError.resourceNotFound(id)
        }
        
        if metadata.storageLocation == .inMemory {
            inMemoryStore.removeValue(forKey: id)
        } else {
            // Remove data file
            let fileURL = urlForResource(id: id, fileExtension: metadata.fileExtension, storageLocation: metadata.storageLocation)
            if fileSystem.fileExists(atPath: fileURL.path) {
                do {
                    try fileSystem.removeItem(at: fileURL)
                } catch {
                    logger?.error("[ResourceManager] Failed to delete resource file \(id): \(error)")
                    throw ResourceManagerError.storageError("Failed to delete resource file: \(error.localizedDescription)")
                }
            }
            
            // Remove metadata sidecar
            let metadataURL = metadataURLForResource(id: id, storageLocation: metadata.storageLocation)
            if fileSystem.fileExists(atPath: metadataURL.path) {
                try? fileSystem.removeItem(at: metadataURL)
            }
        }
        
        resourceIndex.removeValue(forKey: id)
        logger?.info("[ResourceManager] Deleted resource \(id)")
    }
    
    /// Delete all resources, optionally filtered by storage location.
    func deleteAllResources(in location: StorageLocation? = nil) throws {
        let idsToDelete: [UUID]
        if let location {
            idsToDelete = resourceIndex.values.filter { $0.storageLocation == location }.map(\.id)
        } else {
            idsToDelete = Array(resourceIndex.keys)
        }
        
        for id in idsToDelete {
            try deleteResource(id: id)
        }
        
        logger?.info("[ResourceManager] Deleted \(idsToDelete.count) resources")
    }
    
    // MARK: - Public API: Utility
    
    /// Check whether a resource exists in the index.
    func resourceExists(id: UUID) -> Bool {
        resourceIndex[id] != nil
    }
    
    /// Calculate the total storage used by all managed resources (in bytes), optionally filtered by location.
    func totalStorageUsed(in location: StorageLocation? = nil) -> Int {
        let resources: [ResourceMetadata]
        if let location {
            resources = resourceIndex.values.filter { $0.storageLocation == location }
        } else {
            resources = Array(resourceIndex.values)
        }
        return resources.reduce(0) { $0 + $1.byteSize }
    }
    
    /// The total number of managed resources.
    var resourceCount: Int {
        resourceIndex.count
    }
    
    /// Rebuild the in-memory index by scanning metadata sidecar files on disk.
    ///
    /// This is useful on startup to restore knowledge of previously stored resources.
    /// In-memory resources that exist in the current index are preserved.
    func rebuildIndex() throws {
        logger?.info("[ResourceManager] Rebuilding resource index from disk...")
        
        var newIndex: [UUID: ResourceMetadata] = [:]
        
        // Preserve existing in-memory resources
        for (id, metadata) in resourceIndex where metadata.storageLocation == .inMemory {
            newIndex[id] = metadata
        }
        
        // Scan each disk-based storage location
        let diskLocations: [StorageLocation] = [.homeDirectory, .applicationSupport, .temporary]
        for location in diskLocations {
            let directory = directoryURL(for: location)
            guard fileSystem.fileExists(atPath: directory.path) else { continue }
            
            do {
                let files = try fileSystem.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                let metadataFiles = files.filter { $0.pathExtension == "meta" }
                
                for metadataFileURL in metadataFiles {
                    do {
                        let metadataData = try fileSystem.read(from: metadataFileURL)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let metadata = try decoder.decode(ResourceMetadata.self, from: metadataData)
                        
                        // Verify the resource data file still exists alongside its metadata
                        let fileURL = urlForResource(id: metadata.id, fileExtension: metadata.fileExtension, storageLocation: metadata.storageLocation)
                        if fileSystem.fileExists(atPath: fileURL.path) {
                            newIndex[metadata.id] = metadata
                        } else {
                            logger?.warning("[ResourceManager] Resource file missing for \(metadata.id), skipping")
                        }
                    } catch {
                        logger?.warning("[ResourceManager] Failed to read metadata from \(metadataFileURL.path): \(error)")
                    }
                }
            } catch {
                logger?.warning("[ResourceManager] Failed to scan directory \(directory.path): \(error)")
            }
        }
        
        resourceIndex = newIndex
        logger?.info("[ResourceManager] Index rebuilt with \(newIndex.count) resources")
    }
    
    // MARK: - Internal: Directory Helpers
    
    /// Compute the base directory URL for a given storage location.
    func directoryURL(for location: StorageLocation) -> URL {
        switch location {
        case .homeDirectory:
            return fileSystem.homeDirectoryForCurrentUser
                .appendingPathComponent(".swiftAgentHarness")
                .appendingPathComponent("resources")
        case .applicationSupport:
            return fileSystem.applicationSupportDirectory
                .appendingPathComponent("SwiftAgentHarness")
                .appendingPathComponent("resources")
        case .temporary:
            return fileSystem.temporaryDirectory
                .appendingPathComponent("sah-resources")
        case .inMemory:
            // In-memory resources don't use a directory; return a placeholder.
            return fileSystem.temporaryDirectory
                .appendingPathComponent("sah-inmemory")
        }
    }
    
    // MARK: - Private: Storage Helpers
    
    private func ensureDirectoryExists(for location: StorageLocation) throws {
        let directory = directoryURL(for: location)
        if !fileSystem.fileExists(atPath: directory.path) {
            do {
                try fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ResourceManagerError.directoryCreationFailed(directory.path)
            }
        }
    }
    
    private func urlForResource(id: UUID, fileExtension: String?, storageLocation: StorageLocation) -> URL {
        let directory = directoryURL(for: storageLocation)
        var filename = id.uuidString
        if let ext = fileExtension, !ext.isEmpty {
            filename += ".\(ext)"
        }
        return directory.appendingPathComponent(filename)
    }
    
    private func metadataURLForResource(id: UUID, storageLocation: StorageLocation) -> URL {
        let directory = directoryURL(for: storageLocation)
        return directory.appendingPathComponent("\(id.uuidString).meta")
    }
    
    // MARK: - Private: Metadata Persistence
    
    private func saveMetadataSidecar(_ metadata: ResourceMetadata) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let url = metadataURLForResource(id: metadata.id, storageLocation: metadata.storageLocation)
        try fileSystem.write(data, to: url, options: .atomic)
    }
    
    // MARK: - Private: Utilities
    
    private func extractFileExtension(from filename: String) -> String? {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        return ext.isEmpty ? nil : ext
    }
}
