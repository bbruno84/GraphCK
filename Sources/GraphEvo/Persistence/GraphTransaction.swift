import CoreData

public enum GraphTransactionError: LocalizedError {
    case unavailableContext
    case pendingUserChanges
    case storeChanged
    case nestedTransaction

    public var errorDescription: String? {
        switch self {
        case .unavailableContext: return "Graph transaction refused: unavailableContext."
        case .pendingUserChanges: return "Graph transaction refused: pendingUserChanges (unsaved changes in the view context)."
        case .storeChanged: return "Graph transaction refused: storeChanged (the analyzed store revision is no longer current)."
        case .nestedTransaction: return "Graph transaction refused: nestedTransaction."
        }
    }
}

/// Diagnostic captured on the view context queue. `summary` is schema-only;
/// DEBUG builds can additionally capture payloads in `debugDetails`.
public struct GraphTransactionDiagnostics {
    public let checkpoint: String
    public let containerKind: String
    public let inserted: Int
    public let updated: Int
    public let deleted: Int
    public let registered: Int
    public let temporary: Int
    public let groups: [String]
    public let debugDetails: [String]

    public var summary: String {
        "checkpoint=\(checkpoint) container=\(containerKind) inserted=\(inserted) updated=\(updated) deleted=\(deleted) registered=\(registered) temporary=\(temporary) groups=[\(groups.joined(separator: "; "))]"
    }

    fileprivate init(context: NSManagedObjectContext, checkpoint: String, containerKind: String, includeValues: Bool = false) {
        self.checkpoint = checkpoint
        self.containerKind = containerKind
        inserted = context.insertedObjects.count
        updated = context.updatedObjects.count
        deleted = context.deletedObjects.count
        registered = context.registeredObjects.count
        let changed = context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects)
        temporary = changed.filter { $0.objectID.isTemporaryID }.count
        var counts: [String: Int] = [:]
        for object in changed {
            let operation = object.isDeleted ? "delete" : object.isInserted ? "insert" : "update"
            let keys = object.changedValues().keys.sorted().joined(separator: ",")
            let eventKeys = object.changedValuesForCurrentEvent().keys.sorted().joined(separator: ",")
            let key = "\(operation):\(object.entity.name ?? "unknown"):keys=\(keys):eventKeys=\(eventKeys):fault=\(object.isFault)"
            counts[key, default: 0] += 1
        }
        let sorted = counts.keys.sorted()
        groups = sorted.prefix(20).map { "\($0):count=\(counts[$0]!)" } +
            (sorted.count > 20 ? ["omittedGroups=\(sorted.count - 20)"] : [])
#if DEBUG
        debugDetails = includeValues ? changed.sorted {
            $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
        }.prefix(100).map(Self.describe) + (changed.count > 100 ? ["omittedObjects=\(changed.count - 100)"] : []) : []
#else
        debugDetails = []
#endif
    }

#if DEBUG
    private static func value(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let object = value as? NSManagedObject { return object.objectID.uriRepresentation().absoluteString }
        if let data = value as? Data { return "Data(bytes=\(data.count), prefix64=\(data.prefix(64).base64EncodedString()))" }
        let text = String(reflecting: value)
        return String(text.prefix(2048)) + (text.count > 2048 ? "…[truncated]" : "")
    }

    private static func describe(_ object: NSManagedObject) -> String {
        let operation = object.isDeleted ? "delete" : object.isInserted ? "insert" : "update"
        var details = "\(operation) schema=\(object.entity.name ?? "unknown") id=\(object.objectID.uriRepresentation()) fault=\(object.isFault)"
        guard !object.isFault else { return details + " values=unavailable-fault" }
        let changed = object.changedValues()
        let committed = object.committedValues(forKeys: Array(changed.keys))
        for key in changed.keys.sorted() {
            details += " field=\(key) previous=\(value(committed[key])) current=\(value(changed[key]))"
        }
        if let node = object as? ManagedNode {
            details += " nodeType=\(node.type)"
            for item in node.propertySet.filter({ !$0.isFault }).sorted(by: { $0.name < $1.name }).prefix(40) {
                details += " node.\(item.name)=\(value(item.object))"
            }
        }
        if let property = object as? NamedManagedObject {
            details += " property=\(property.name)"
            let owner = property.node ?? (object.committedValues(forKeys: ["node"])["node"] as? ManagedNode)
            if let owner {
                details += " ownerID=\(owner.objectID.uriRepresentation()) ownerFault=\(owner.isFault)"
                if !owner.isFault {
                    details += " ownerType=\(owner.type)"
                    for item in owner.propertySet.filter({ !$0.isFault && !$0.isDeleted }).sorted(by: { $0.name < $1.name }).prefix(40) {
                        details += " owner.\(item.name)=\(value(item.object))"
                    }
                }
            }
        }
        return details
    }
#endif
}

extension Graph {
#if DEBUG
    /// Read-only, payload-bearing diagnostic for application-owned test logs.
    /// Does not save, roll back, obtain permanent IDs or process pending changes.
    public func pendingChangeDiagnostics(checkpoint: String) -> GraphTransactionDiagnostics? {
        guard let context = managedObjectContext else { return nil }
        return context.performAndWait {
            GraphTransactionDiagnostics(context: context, checkpoint: checkpoint,
                containerKind: persistentContainer is NSPersistentCloudKitContainer ? "CloudKit" : "local", includeValues: true)
        }
    }
#endif
    /// Runs a public Graph facade against an isolated, pinned private context.
    /// The body must not escape Graph/Nodes, call sync, or perform external writes.
    /// Commit uses NSErrorMergePolicy; conflicts fail and can be retried from a
    /// fresh snapshot. This does not suspend CloudKit: concurrent inserts after
    /// the final generation check require a subsequent reconciliation pass.
    public func transaction<T>(_ body: (Graph) throws -> T) throws -> T {
        guard !isTransactionFacade else { throw GraphTransactionError.nestedTransaction }
        guard let view = managedObjectContext,
              let coordinator = view.persistentStoreCoordinator else {
            throw GraphTransactionError.unavailableContext
        }
        try view.performAndWait { try rejectPendingChanges(in: view, checkpoint: "beforeBody") }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSErrorMergePolicy
        context.transactionAuthor = GraphDeviceAuthor.current()
        var savedObjectIDs: [AnyHashable: Any]?
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave,
            object: context, queue: nil) { notification in
                var ids: [AnyHashable: Any] = [:]
                for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
                    if let objects = notification.userInfo?[key] as? Set<NSManagedObject> {
                        ids[key] = objects.map(\.objectID)
                    }
                }
                savedObjectIDs = ids
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let result: T = try context.performAndWait {
            do {
                if configuration.backend == .sqlite {
                    try context.setQueryGenerationFrom(.current)
                    let pin = NSFetchRequest<NSManagedObjectID>(entityName: ModelIdentifier.entityName)
                    pin.resultType = .managedObjectIDResultType
                    pin.fetchLimit = 1
                    _ = try context.fetch(pin)
                }
                let facade = Graph(transactionContext: context, configuration: configuration)
                return try body(facade)
            } catch {
                context.rollback()
                throw error
            }
        }
        do {
            // User edits may have arrived while the private body was running.
            // Hold the view queue only for the final check/save/merge, not for
            // snapshot computation, so an unsaved edit cannot be overwritten.
            try view.performAndWait {
                try rejectPendingChanges(in: view, checkpoint: "beforeCommit")
                let affectedIDs = context.performAndWait {
                    context.deletedObjects.isEmpty ? [] :
                        context.updatedObjects.union(context.deletedObjects).map(\.objectID)
                }
                // Refault affected, clean view objects BEFORE deleting their
                // backing rows. Merging a property deletion into a materialized
                // owner can otherwise leave that deletion pending in the view.
                // Never reset the context or discard genuine unsaved user edits.
                for id in affectedIDs {
                    if let object = view.registeredObject(for: id) {
                        view.refresh(object, mergeChanges: false)
                    }
                }
                try context.performAndWait {
                    guard context.hasChanges else { return }
                    if configuration.backend == .sqlite {
                        let probe = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                        probe.persistentStoreCoordinator = coordinator
                        let latest = try probe.performAndWait { () -> NSQueryGenerationToken? in
                            try probe.setQueryGenerationFrom(.current)
                            // Resolve the lazy .current token to an actual store
                            // generation before comparing it with a fetched context.
                            let request = NSFetchRequest<NSManagedObjectID>(entityName: ModelIdentifier.entityName)
                            request.resultType = .managedObjectIDResultType
                            request.fetchLimit = 1
                            _ = try probe.fetch(request)
                            return probe.queryGenerationToken
                        }
                        guard context.queryGenerationToken == latest else { throw GraphTransactionError.storeChanged }
                    }
                    try context.save()
                }
                if let savedObjectIDs {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: savedObjectIDs, into: [view])
                    let deletedIDs = Set(savedObjectIDs[NSDeletedObjectsKey] as? [NSManagedObjectID] ?? [])
                    // Core Data can leave retained, already-committed deletions
                    // pending after the merge. Finalize ONLY those exact IDs:
                    // never save inserts, updates, or unrelated user deletions.
                    // A rollback would re-register the deleted objects and the
                    // deferred automatic merge would make them pending again.
                    // SQLite regression tests verify this finalization adds no
                    // second persistent-history transaction.
                    if view.insertedObjects.isEmpty, view.updatedObjects.isEmpty,
                       !view.deletedObjects.isEmpty,
                       view.deletedObjects.allSatisfy({ deletedIDs.contains($0.objectID) && $0.changedValues().isEmpty }) {
                        try view.save()
                    }
                }
            }
        } catch {
            context.performAndWait { context.rollback() }
            throw error
        }
        return result
    }

    private func rejectPendingChanges(in context: NSManagedObjectContext, checkpoint: String) throws {
        guard !isCloudPurgeInProgress else { throw GraphCloudPurgeError.writesBlockedDuringPurge }
        guard context.hasChanges else { return }
        let kind = persistentContainer is NSPersistentCloudKitContainer ? "CloudKit" : "local"
        var includeValues = false
#if DEBUG
        includeValues = true
#endif
        let diagnostics = GraphTransactionDiagnostics(context: context, checkpoint: checkpoint, containerKind: kind, includeValues: includeValues)
        emit(.error(.transaction(underlying: .pendingUserChanges, diagnostics: diagnostics)))
        throw GraphTransactionError.pendingUserChanges
    }
}
