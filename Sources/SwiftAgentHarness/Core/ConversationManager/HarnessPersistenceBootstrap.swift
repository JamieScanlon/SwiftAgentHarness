//
//  SwiftData container creation with store quarantine on schema mismatch.
//

import Foundation
import Logging
import SwiftData

enum HarnessPersistenceBootstrap {
    /// Builds default store URL under Application Support when `dataStoreURL` is nil.
    static func resolvedStoreURL(dataStoreURL: URL?) -> URL {
        if let dataStoreURL {
            return dataStoreURL
        }
        return HarnessHostPaths.defaultSwiftDataStoreURL()
    }

    static func ensureParentDirectories(
        dataStoreURL: URL?,
        storeURL: URL,
        allowsSwiftDataSave: Bool,
        logger: Logger?
    ) {
        let fileManager = FileManager.default
        if dataStoreURL == nil {
            do {
                let directoryURL = storeURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                fatalError("Could not create Application Support folder for \(HarnessHostPaths.layout.applicationSupportDirectoryName)")
            }
        } else if allowsSwiftDataSave {
            let parent = storeURL.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger?.error("Failed to create parent directory for custom data store: \(error)")
            }
        }
    }

    /// Moves the SwiftData store bundle (`.store`, `-shm`, `-wal`) into a timestamped `recovery-*` sibling folder.
    static func quarantineSwiftDataStoreBundle(at storeURL: URL, logger: Logger?) {
        let fileManager = FileManager.default
        let storeDir = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantineDir = storeDir.appendingPathComponent("recovery-\(timestamp)")
        do {
            try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        } catch {
            logger?.error("Could not create recovery directory at \(quarantineDir.path): \(error)")
            return
        }

        let paths = [
            storeURL,
            storeDir.appendingPathComponent("\(baseName)-shm"),
            storeDir.appendingPathComponent("\(baseName)-wal"),
        ]
        for path in paths where fileManager.fileExists(atPath: path.path) {
            let target = quarantineDir.appendingPathComponent(path.lastPathComponent)
            do {
                try fileManager.moveItem(at: path, to: target)
                logger?.warning("Moved SwiftData store file to recovery folder: \(target.path)")
            } catch {
                logger?.error("Failed to move \(path.path) to \(target.path): \(error)")
            }
        }
    }

    static func makeModelContainer(
        dataStoreURL: URL?,
        allowsSwiftDataSave: Bool,
        logger: Logger?
    ) -> ModelContainer {
        let fileURL = resolvedStoreURL(dataStoreURL: dataStoreURL)
        ensureParentDirectories(dataStoreURL: dataStoreURL, storeURL: fileURL, allowsSwiftDataSave: allowsSwiftDataSave, logger: logger)

        let schema = HarnessPersistenceSchema.latest
        let defaultConfiguration = ModelConfiguration(
            HarnessHostPaths.layout.swiftDataModelConfigurationName,
            schema: schema,
            url: fileURL,
            allowsSave: allowsSwiftDataSave
        )

        func makeContainer() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: defaultConfiguration)
        }

        func detailedErrorDescription(_ error: Error) -> String {
            let nsError = error as NSError
            var parts: [String] = [
                "domain=\(nsError.domain)",
                "code=\(nsError.code)",
                "localizedDescription=\(nsError.localizedDescription)",
            ]
            if !nsError.userInfo.isEmpty {
                parts.append("userInfo=\(nsError.userInfo)")
            }
            return parts.joined(separator: " | ")
        }

        do {
            return try makeContainer()
        } catch {
            logger?.error("Failed to create ModelContainer: \(detailedErrorDescription(error))")
            if allowsSwiftDataSave {
                logger?.warning(
                    "Attempting one-time SwiftData store quarantine after open failure (harness session data is unaffected)"
                )
                quarantineSwiftDataStoreBundle(at: fileURL, logger: logger)
                do {
                    return try makeContainer()
                } catch {
                    logger?.error("ModelContainer recovery attempt failed: \(detailedErrorDescription(error))")
                    fatalError("Could not initialise the container: \(error)")
                }
            } else {
                fatalError("Could not initialise the container: \(error)")
            }
        }
    }
}
