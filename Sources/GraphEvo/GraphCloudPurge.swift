import CoreData
import CloudKit

/// Errors raised before GraphEvo starts a remote CloudKit purge.
public enum GraphCloudPurgeError: LocalizedError, Equatable {
    case notSupportedDuringTests
    case cloudKitNotConfigured
    case cloudContainerUnavailable
    case cloudStoreUnavailable
    case purgeAlreadyInProgress
    case invalidCompletion
    case writesBlockedDuringPurge

    public var errorDescription: String? {
        switch self {
        case .notSupportedDuringTests:
            return "CloudKit purge is disabled while running under tests."
        case .cloudKitNotConfigured:
            return "A CloudKit container identifier is required to purge the store."
        case .cloudContainerUnavailable:
            return "The effective persistent container is not an NSPersistentCloudKitContainer or is not ready."
        case .cloudStoreUnavailable:
            return "No loaded persistent store configured for CloudKit was found."
        case .purgeAlreadyInProgress:
            return "A CloudKit purge is already in progress for this graph."
        case .invalidCompletion:
            return "CloudKit reported an incomplete purge result."
        case .writesBlockedDuringPurge:
            return "CloudKit purge is in progress. Retry saving after completion."
        }
    }
}

extension Graph {
    /// Purges GraphEvo's Core Data CloudKit zone from the remote private
    /// database. This does not delete or recreate the local SQLite store.
    ///
    /// The completion is delivered on the main queue after Core Data invokes
    /// its purge completion. A nil error is considered success only when the
    /// expected zone ID is also returned. Apple removes the corresponding
    /// local managed objects as well. The SQLite files are retained. After
    /// success the view context is reset and writes are enabled before the
    /// callback. The caller must reload cached application objects there.
    public func purgeCloudStore(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        purgeCloudStore(allowDuringTests: false, completion: completion)
    }

    private func purgeCloudStore(
        allowDuringTests: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard allowDuringTests || !Self.isRunningUnderTests else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.notSupportedDuringTests), completion: completion)
            return
        }

        guard configuration.cloudKitContainerIdentifier != nil else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudKitNotConfigured), completion: completion)
            return
        }

        guard let container = persistentContainer as? NSPersistentCloudKitContainer else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudContainerUnavailable), completion: completion)
            return
        }

        guard let store = cloudKitPersistentStore(in: container) else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudStoreUnavailable), completion: completion)
            return
        }

        executeCloudPurge(container: container, store: store, executor: { container, zone, store, callback in
            container.purgeObjectsAndRecordsInZone(with: zone, in: store, completion: callback)
        }, completion: completion)
    }

    private func executeCloudPurge(
        container: NSPersistentCloudKitContainer,
        store: NSPersistentStore,
        executor: @escaping (NSPersistentCloudKitContainer, CKRecordZone.ID, NSPersistentStore, @escaping (CKRecordZone.ID?, Error?) -> Void) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let context = managedObjectContext else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudContainerUnavailable), completion: completion)
            return
        }

        // Serialize the gate with transaction commits on the view queue.
        // Never hold a thread-owned lock across an asynchronous callback.
        context.perform {
            guard self.beginCloudPurge() else {
                self.deliverPurgeResult(.failure(GraphCloudPurgeError.purgeAlreadyInProgress), completion: completion)
                return
            }
            do {
                if context.hasChanges {
                    try context.save()
                }
                let zoneID = CKRecordZone.ID(
                    zoneName: "com.apple.coredata.cloudkit.zone",
                    ownerName: CKCurrentUserDefaultName
                )
                executor(container, zoneID, store) { purgedZoneID, error in
                    let result: Result<Void, Error>
                    if let error {
                        result = .failure(error)
                    } else if purgedZoneID != zoneID {
                        result = .failure(GraphCloudPurgeError.invalidCompletion)
                    } else {
                        result = .success(())
                    }
                    context.perform {
                        if case .success = result {
                            // Discard stale registered objects after Apple's purge.
                            context.reset()
                        }
                        self.endCloudPurge()
                        self.deliverPurgeResult(result, completion: completion)
                    }
                }
            } catch {
                self.endCloudPurge()
                self.deliverPurgeResult(.failure(error), completion: completion)
            }
        }
    }

    private func cloudKitPersistentStore(
        in container: NSPersistentCloudKitContainer
    ) -> NSPersistentStore? {
        let cloudDescriptions = container.persistentStoreDescriptions.filter {
            $0.cloudKitContainerOptions != nil
        }
        guard !cloudDescriptions.isEmpty else { return nil }

        return container.persistentStoreCoordinator.persistentStores.first { store in
            guard let storeURL = store.url else { return false }
            return cloudDescriptions.contains { description in
                description.url?.standardizedFileURL == storeURL.standardizedFileURL
            }
        }
    }

    private func deliverPurgeResult(
        _ result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

#if DEBUG
extension Graph {
    /// Internal validation seam used by offline tests. It deliberately keeps
    /// the public API's production/test guard intact.
    internal func validateCloudPurgeForTesting(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        purgeCloudStore(allowDuringTests: true, completion: completion)
    }

    /// Test-only seam for exercising completion/error handling without a real
    /// CloudKit container. It is not part of the public API.
    internal func purgeCloudStoreForTesting(
        container: NSPersistentCloudKitContainer,
        store: NSPersistentStore,
        executor: @escaping (NSPersistentCloudKitContainer, CKRecordZone.ID, NSPersistentStore, @escaping (CKRecordZone.ID?, Error?) -> Void) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let identifier = configuration.cloudKitContainerIdentifier, !identifier.isEmpty else {
            deliverPurgeResult(.failure(GraphCloudPurgeError.cloudKitNotConfigured), completion: completion)
            return
        }
        executeCloudPurge(container: container, store: store, executor: executor, completion: completion)
    }
}
#endif
