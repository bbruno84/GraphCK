//
//  PersistentHistoryTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 20/09/25.
//


// MARK: - PersistentHistoryTests

#if canImport(XCTest)
import XCTest
@testable import GraphEvo
import CoreData

final class PersistentHistoryTests: XCTestCase {
    func testPurgeHistoryReplayLeavesViewClean() throws {
        try assertPurgeReplay()
    }

    func testPurgeHistoryReplayPreservesUnsavedInsertion() throws {
        try assertPurgeReplay(userEdit: "insert")
    }

    func testPurgeHistoryReplayPreservesUnsavedUpdate() throws {
        try assertPurgeReplay(userEdit: "update")
    }

    func testPurgeHistoryReplayPreservesUnrelatedDeletion() throws {
        try assertPurgeReplay(userEdit: "delete")
    }

    private func assertPurgeReplay(userEdit: String? = nil) throws {
        var config = GraphStoreConfiguration()
        config.name = UUID().uuidString
        config.location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 10)
        let view = try XCTUnwrap(graph.managedObjectContext)
        let bg = try XCTUnwrap(graph.newBackgroundContext())
        try bg.performAndWait {
            bg.transactionAuthor = "REMOTE-PURGE-TEST"
            let scoped = Graph(transactionContext: bg, configuration: config)
            for index in 0..<20 {
                let bill = Entity("Bill", graph: scoped)
                bill[dynamicMember: "uuid"] = "bill-\(index)"
                bill[dynamicMember: "amount"] = 42.0
            }
            try bg.save()
            // Simulate persisted purge deletions without merging into the view.
            for entity in try XCTUnwrap(bg.persistentStoreCoordinator).managedObjectModel.entities where entity.superentity == nil {
                let request = NSFetchRequest<NSManagedObject>(entityName: try XCTUnwrap(entity.name))
                try bg.fetch(request).forEach(bg.delete)
            }
            try bg.save()
        }
        view.reset()
        let survivor = Entity("UserData", graph: graph)
        survivor[dynamicMember: "amount"] = 12.0
        graph.sync()
        var inserted: Entity?
        switch userEdit {
        case "insert": inserted = Entity("Unsaved", graph: graph)
        case "update": survivor[dynamicMember: "amount"] = 99.0
        case "delete": survivor.delete()
        default: break
        }
        func historyCount() throws -> Int {
            try bg.performAndWait {
                let result = try bg.execute(NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)) as? NSPersistentHistoryResult
                return try XCTUnwrap(result?.result as? [NSPersistentHistoryTransaction]).count
            }
        }
        let historyBefore = try historyCount()
        graph.watchReportSources = [.cloud]
        graph.watchReportCompletion = { _, _ in }
        let processed = expectation(description: "history replay")
        graph.processPersistentHistoryBatch { _ in processed.fulfill() }
        wait(for: [processed], timeout: 10)
        let delivery = expectation(description: "delivery settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delivery.fulfill() }
        wait(for: [delivery], timeout: 5)
        XCTAssertEqual(try historyCount(), historyBefore, "History replay must not create a new persistent transaction")
        if userEdit == nil {
            XCTAssertFalse(view.hasChanges, graph.pendingChangeDiagnostics(checkpoint: "purgeReplay")!.summary)
            XCTAssertNoThrow(try graph.transaction { _ in })
        } else {
            XCTAssertTrue(view.hasChanges)
            XCTAssertThrowsError(try graph.transaction { _ in })
            switch userEdit {
            case "insert": XCTAssertTrue(try XCTUnwrap(inserted).node.isInserted)
            case "update": XCTAssertEqual(survivor[dynamicMember: "amount"] as? Double, 99.0)
            case "delete": XCTAssertTrue(survivor.node.isDeleted)
            default: break
            }
        }
    }

    override func setUp() {
        super.setUp()
        GraphMigrationManager.resetForTesting()
    }

    override func tearDown() {
        GraphMigrationManager.resetForTesting()
        super.tearDown()
    }

    private struct AppDataVersionMigration: GraphMigration {
        let id = "PersistentHistoryTests.AppDataVersionMigration"
        let version = 1

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(.skipped)
        }

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            false
        }

        func recognizesLegacyCompletion(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?
        ) -> Bool {
            false
        }

        func handleRemoteChanges(
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            inserted: [NSManagedObjectID],
            updated: [NSManagedObjectID]
        ) {
            guard let graph, let moc = graph.managedObjectContext else { return }
            let objectIDs = inserted + updated
            moc.performAndWait {
                for objectID in objectIDs {
                    guard let object = try? moc.existingObject(with: objectID),
                          object.entity.name == "ManagedEntityProperty" else { continue }
                    object.setValue(configuration?.requiredAppDataVersion, forKey: "appDataVersion")
                }
                if moc.hasChanges {
                    try? moc.save()
                }
            }
        }
    }

    func testSimulatedRemoteChangeTriggersMigration() throws {
        GraphMigrationManager.registerMigration(AppDataVersionMigration())

        // 1. Create a fresh Graph with unique name
        var config = GraphStoreConfiguration()
        config.name = "PersistentHistory-\(UUID().uuidString)"
        let graph = Graph(configuration: config)

        // 2. Insert a ManagedEntityProperty without appDataVersion
        let nbg = graph.newBackgroundContext()
        guard let bg = nbg else {
            XCTFail("Could not create a background context")
            return
        }
        var objectID: NSManagedObjectID!
        var backgroundSaveError: Error?
        bg.performAndWait {
            // Mark this write as coming from a different author to simulate a *remote* change
            // so that Persistent History processing does not skip it as self-authored.
            bg.transactionAuthor = "REMOTE-TEST-AUTHOR"
            let obj = NSEntityDescription.insertNewObject(
                forEntityName: "ManagedEntityProperty",
                into: bg
            )
            obj.setValue("testProp", forKey: "name")
            do {
                try bg.save()
            } catch {
                backgroundSaveError = error
            }
            objectID = obj.objectID
        }
        XCTAssertNil(backgroundSaveError, "The simulated remote transaction must be saved")
        XCTAssertFalse(objectID.isTemporaryID, "The simulated remote transaction must produce a permanent object ID")

        // 3. Simulate remote change notification
        graph.processPersistentHistoryForRemoteChange()

        // 4. Wait a short time for async processing
        let exp = expectation(description: "wait for PH")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(
            graph.ph_debug_lastTokenExists(),
            "Processing a real local persistent-history transaction must advance and persist the token"
        )

        // 5. Reload object and check appDataVersion updated
        let refreshed = try graph.managedObjectContext?.existingObject(with: objectID)
        graph.managedObjectContext?.refreshAllObjects()
        let version = refreshed?.value(forKey: "appDataVersion") as? Int

        XCTAssertEqual(
            version,
            graph.configuration.requiredVersions.appData,
            "appDataVersion should be upgraded on remote change"
        )
    }
}
#endif
