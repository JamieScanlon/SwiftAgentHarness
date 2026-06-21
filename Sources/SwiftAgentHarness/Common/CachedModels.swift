import Foundation
import SwiftData

public enum HarnessSchemaV22: VersionedSchema {
    nonisolated(unsafe) public static var versionIdentifier = Schema.Version(22, 0, 0)

    @Model
    public final class CachedSchemaAnchor {
        @Attribute(.unique) public var id: UUID

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }

    public static var models: [any PersistentModel.Type] {
        [CachedSchemaAnchor.self]
    }

    public static var persistenceSchema: Schema {
        Schema(models)
    }
}

public enum HarnessPersistenceSchema {
    public static var latest: Schema { HarnessSchemaV22.persistenceSchema }
    public static var latestVersioned: any VersionedSchema.Type { HarnessSchemaV22.self }
}
