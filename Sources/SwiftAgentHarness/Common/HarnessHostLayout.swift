import Foundation

/// Host-supplied names for Application Support layout and related on-disk paths.
public struct HarnessHostLayout: Sendable, Equatable {
    public var applicationSupportDirectoryName: String
    public var swiftDataStoreFileName: String
    public var swiftDataModelConfigurationName: String
    public var userSettingsDirectoryName: String

    public init(
        applicationSupportDirectoryName: String,
        swiftDataStoreFileName: String,
        swiftDataModelConfigurationName: String? = nil,
        userSettingsDirectoryName: String = ".agent-harness"
    ) {
        self.applicationSupportDirectoryName = applicationSupportDirectoryName
        self.swiftDataStoreFileName = swiftDataStoreFileName
        self.swiftDataModelConfigurationName = swiftDataModelConfigurationName ?? applicationSupportDirectoryName
        self.userSettingsDirectoryName = userSettingsDirectoryName
    }

    public static let genericDefault = HarnessHostLayout(
        applicationSupportDirectoryName: "AgentHarness",
        swiftDataStoreFileName: "harness.store"
    )
}

public enum HarnessHostPaths {
    private final class LayoutBox: @unchecked Sendable {
        var layout: HarnessHostLayout = .genericDefault
    }

    private static let layoutBox = LayoutBox()

    public static var layout: HarnessHostLayout {
        layoutBox.layout
    }

    public static func configure(_ layout: HarnessHostLayout) {
        layoutBox.layout = layout
    }

    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["SAH_CONFIG_HOME"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.sahHomeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directoryName = resolvedApplicationSupportDirectoryName()
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func sandboxRegistryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("sandbox-registry.json")
    }

    public static func defaultSwiftDataStoreURL(fileManager: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent(layout.swiftDataStoreFileName)
    }

    public static func userSettingsURL(fileManager: FileManager = .default) -> URL {
        fileManager.sahHomeDirectory
            .appendingPathComponent(layout.userSettingsDirectoryName, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private static func resolvedApplicationSupportDirectoryName() -> String {
        if let raw = ProcessInfo.processInfo.environment["SAH_APPLICATION_SUPPORT_NAME"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return raw
        }
        return layout.applicationSupportDirectoryName
    }
}
