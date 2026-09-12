import XCTest
import CoreData
import SQLite3
@testable import GraphEvo

final class GraphLocalStoreResetTests: XCTestCase {
    func testApplicationPreflightFailureNeverOpensStoreWithoutMigrations() throws {
        let config = configuration()
        let graph = Graph(configuration: config, migrationEnabled: false, preflight: {
            throw CocoaError(.validationMissingMandatoryProperty)
        })
        let failed = expectation(description: "preflight failed")
        graph.whenReady { result in
            if case .success = result { XCTFail("Rejected configuration opened") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.resolvedStoreURL.path))
    }

    private func configuration() -> GraphStoreConfiguration {
        var config = GraphStoreConfiguration()
        config.location = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphReset-" + UUID().uuidString + ".sqlite")
        config.disablesCloudKit = true
        return config
    }

    private func createStore(_ config: GraphStoreConfiguration) throws {
        try autoreleasepool {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Model.create())
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,
                configurationName: nil, at: config.location, options: [NSPersistentHistoryTrackingKey: true])
            try coordinator.remove(store)
        }
    }

    func testResetCallsBackupBeforeDestroyAndCanReopen() throws {
        let config = configuration()
        try createStore(config)
        let oldID = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: config.location)[NSStoreUUIDKey] as? String
        var backedUp = false
        try Graph.resetLocalStore(configuration: config) { url in
            XCTAssertEqual(url, config.location)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            backedUp = true
        }
        XCTAssertTrue(backedUp)
        try createStore(config)
        let newID = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: config.location)[NSStoreUUIDKey] as? String
        XCTAssertNotEqual(oldID, newID)
    }

    func testBackupFailurePreservesStore() throws {
        let config = configuration()
        try createStore(config)
        let before = try Data(contentsOf: config.location)
        XCTAssertThrowsError(try Graph.resetLocalStore(configuration: config) { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(try Data(contentsOf: config.location), before)
    }

    func testOpenGraphRefusesResetBeforeCallback() throws {
        let config = configuration()
        let graph = Graph(configuration: config, migrationEnabled: false)
        let ready = expectation(description: "ready")
        graph.whenReady { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        XCTAssertThrowsError(try Graph.resetLocalStore(configuration: config) { _ in
            XCTFail("Backup callback must not run for an open graph")
        }) { error in
            guard case GraphLocalStoreResetError.storeIsOpen = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(graph.isReady)
    }

    func testMissingStoreStillAllowsIntentPersistence() throws {
        let config = configuration()
        var persisted = false
        try Graph.resetLocalStore(configuration: config) { _ in persisted = true }
        XCTAssertTrue(persisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.location.path))
    }

    func testSQLiteWriterLockRefusesResetAndPreservesStore() throws {
        let config = configuration()
        try createStore(config)
        let oldID = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: config.location)[NSStoreUUIDKey] as? String
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(config.location.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try Graph.resetLocalStore(configuration: config) { _ in })
        XCTAssertEqual(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: config.location)[NSStoreUUIDKey] as? String, oldID)
    }
}
