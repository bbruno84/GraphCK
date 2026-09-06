//
//  GraphWatchEventCoordinator.swift
//  GraphEvo
//

import CoreData
import Foundation

internal enum GraphWatchLocalCapture {
    private static let lock = NSLock()
    private static var suppressedContexts = Set<ObjectIdentifier>()

    static func isSuppressed(_ context: NSManagedObjectContext) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressedContexts.contains(ObjectIdentifier(context))
    }

    static func whileSuppressed(_ context: NSManagedObjectContext, _ body: () -> Void) {
        let identifier = ObjectIdentifier(context)
        lock.lock()
        suppressedContexts.insert(identifier)
        lock.unlock()
        defer {
            lock.lock()
            suppressedContexts.remove(identifier)
            lock.unlock()
        }
        body()
    }
}

internal final class GraphWatchEventCoordinator {
    private weak var graph: Graph?
    private weak var context: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    private var pendingLocalDeletions: [GraphWatchEventEnvelope] = []
    private let cloudDelivery: GraphWatchBatchDeliveryCoordinator

    init(graph: Graph, context: NSManagedObjectContext) {
        self.graph = graph
        self.context = context
        self.cloudDelivery = GraphWatchBatchDeliveryCoordinator(graph: graph, context: context)
        installObservers(context: context)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    internal func requestCloudDelivery() {
        cloudDelivery.request()
    }

    internal func prepareCloudDelivery(startingAfter token: NSPersistentHistoryToken?) {
        cloudDelivery.prepare(startingAfter: token)
    }

    private func installObservers(context: NSManagedObjectContext) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.contextObjectsDidChange(notification)
        })
        observers.append(center.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.contextDidSave(notification)
        })
        observers.append(center.addObserver(
            forName: .GraphEvoSimulatedRemoteChange,
            object: context,
            queue: nil
        ) { [weak self] notification in
            self?.remoteChange(notification)
        })
    }

    private func contextObjectsDidChange(_ notification: Notification) {
        guard let context, !GraphWatchLocalCapture.isSuppressed(context) else { return }
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            pendingLocalDeletions.removeAll()
            return
        }
        let deleted = managedObjects(notification.userInfo?[NSDeletedObjectsKey])
        guard !deleted.isEmpty else { return }
        let envelopes = materialize(deleted, operation: .delete, source: .local)
        pendingLocalDeletions.append(contentsOf: envelopes)
    }

    private func contextDidSave(_ notification: Notification) {
        guard let context, !GraphWatchLocalCapture.isSuppressed(context) else { return }
        let inserted = materialize(
            managedObjects(notification.userInfo?[NSInsertedObjectsKey]),
            operation: .insert,
            source: .local
        )
        let updated = materialize(
            managedObjects(notification.userInfo?[NSUpdatedObjectsKey]),
            operation: .update,
            source: .local
        )

        var deleted = pendingLocalDeletions
        pendingLocalDeletions.removeAll()
        let capturedURIs = Set(deleted.map(\.objectURI))
        let fallbackDeleted = managedObjects(notification.userInfo?[NSDeletedObjectsKey])
            .filter { !capturedURIs.contains($0.objectID.uriRepresentation().absoluteString) }
        deleted.append(contentsOf: materialize(fallbackDeleted, operation: .delete, source: .local))

        deliverReport(inserted + updated + deleted, source: .local)
    }

    private func remoteChange(_ notification: Notification) {
        guard let context else { return }
        if notification.userInfo?[GraphEvoOrderedRemoteChangesKey] != nil {
            // Legacy Watch instances observe the original notification
            // directly. The batch path owns materialization and retry for
            // Persistent History reports, so do not materialize a second
            // copy here or let a batch failure affect legacy callbacks.
            cloudDelivery.request()
            return
        }

        let envelopes: [GraphWatchEventEnvelope]
        let inserted = materialize(managedObjects(notification.userInfo?[NSInsertedObjectsKey], in: context), operation: .insert, source: .cloud)
        let updated = materialize(managedObjects(notification.userInfo?[NSUpdatedObjectsKey], in: context), operation: .update, source: .cloud)
        let deleted = materialize(managedObjects(notification.userInfo?[NSDeletedObjectsKey], in: context), operation: .delete, source: .cloud)
        envelopes = inserted + updated + deleted

        // Direct/simulated notifications do not have a Persistent History
        // delivery cursor and retain the existing batch behavior.
        deliverReport(envelopes, source: .cloud)
    }

    private func materialize(
        _ objects: [NSManagedObject],
        operation: GraphWatchChangeOperation,
        source: GraphSource,
        transactionIndex: Int = 0,
        changeIndex: Int = 0
    ) -> [GraphWatchEventEnvelope] {
        guard let graph else { return [] }
        return objects.enumerated().compactMap { offset, object in
            do {
                return try GraphWatchEventMaterializer.materialize(
                    object: object,
                    operation: operation,
                    source: source,
                    transactionIndex: transactionIndex,
                    changeIndex: changeIndex + offset
                )
            } catch {
                // Preserve the legacy Watch error contract. The retryable
                // warning is emitted only by the persistent-history batch
                // delivery path.
                graph.emit(.error(.watchEventMaterialization(source: source, underlying: error)))
                return nil
            }
        }
    }

    private func deliverReport(_ envelopes: [GraphWatchEventEnvelope], source: GraphSource) {
        guard let graph,
              graph.watchReportSources.contains(source),
              graph.watchReportCompletion != nil,
              !envelopes.isEmpty else { return }
        let ordered = envelopes.sorted { $0.isOrdered(before: $1) }
        let deliver = { [weak graph] in
            guard let graph else { return }
            let report = GraphWatchReport(graph: graph, source: source, events: ordered.map(\.event))
            graph.watchReportCompletion?(report, nil)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private func managedObjects(_ value: Any?, in context: NSManagedObjectContext? = nil) -> [NSManagedObject] {
        guard let set = value as? NSSet else { return [] }
        return set.allObjects.compactMap { value in
            if let object = value as? NSManagedObject { return object }
            if let objectID = value as? NSManagedObjectID, let context { return context.object(with: objectID) }
            return nil
        }.sorted {
            $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
        }
    }
}
