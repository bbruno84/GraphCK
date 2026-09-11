import CoreData

public enum GraphLocalStoreResetError: LocalizedError {
    case requiresSQLite
    case storeIsOpen

    public var errorDescription: String? {
        switch self {
        case .requiresSQLite: return "Local reset requires an explicit persistent SQLite store."
        case .storeIsOpen: return "Local reset refused: the store is already open in this process."
        }
    }
}

extension Graph {
    /// Resets only the local SQLite replica before Graph opens it. This never
    /// creates a CloudKit container or sends a remote purge. The caller must
    /// create a verified backup and persist its recovery intent in beforeReset.
    /// Any callback error prevents destruction. Never open a Graph in that body.
    /// Core Data honors file locks; unsafe force-destruction is never enabled.
    public static func resetLocalStore(
        configuration: GraphStoreConfiguration,
        beforeReset: (URL) throws -> Void
    ) throws {
        let configuration = try configuration.resolvingEnvironment()
        let url = configuration.resolvedStoreURL.standardizedFileURL
        guard configuration.backend == .sqlite, url.isFileURL,
              url.pathExtension.lowercased() == "sqlite" else {
            throw GraphLocalStoreResetError.requiresSQLite
        }
        try GraphContextRegistry.shared.withStoreOpenLock {
            guard GraphContextRegistry.shared.context(for: configuration.storeIdentityKey) == nil else {
                throw GraphLocalStoreResetError.storeIsOpen
            }
            try beforeReset(url)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.create())
            try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: [
                NSPersistentHistoryTrackingKey: true,
                NSPersistentStoreRemoteChangeNotificationPostOptionKey: true,
                NSPersistentStoreTimeoutOption: 1,
                NSPersistentStoreForceDestroyOption: false
            ])
        }
    }
}
