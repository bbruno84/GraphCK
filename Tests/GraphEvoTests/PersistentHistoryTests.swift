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
