import XCTest
import CoreData
import CloudKit
@testable import GraphEvo

final class GraphCloudPurgeTests: XCTestCase {
    func testAsynchronousPurgeGatesWritesAndRetainsStore() throws {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        _ = Entity("BeforeWipe", graph: graph)
        let container = NSPersistentCloudKitContainer(name: "PurgeTests", managedObjectModel: Model.create())
        let store = try XCTUnwrap(graph.persistentContainer?.persistentStoreCoordinator.persistentStores.first)
        let done = expectation(description: "asynchronous purge")
        graph.purgeCloudStoreForTesting(container: container, store: store, executor: { _, zone, _, callback in
            XCTAssertTrue(graph.isCloudPurgeInProgress)
            do {
                try graph.transaction { _ in XCTFail("Must not enter transaction") }
                XCTFail("Expected purge gate")
            } catch { XCTAssertEqual(error as? GraphCloudPurgeError, .writesBlockedDuringPurge) }
            graph.sync { success, error in
                XCTAssertFalse(success)
                XCTAssertEqual(error as? GraphCloudPurgeError, .writesBlockedDuringPurge)
            }
            // Simulate Apple's deletion independently of the gated public save API.
            Search<Entity>(graph: graph).where(.type("BeforeWipe")).sync().forEach { $0.delete() }
            do { try graph.managedObjectContext.save() }
            catch { XCTFail("Simulated purge failed: \(error)") }
            DispatchQueue.global().async { callback(zone, nil) }
        }) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(graph.isCloudPurgeInProgress)
            XCTAssertFalse(graph.managedObjectContext.hasChanges)
            XCTAssertTrue(Search<Entity>(graph: graph).where(.type("BeforeWipe")).sync().isEmpty)
            XCTAssertTrue(graph.persistentContainer!.persistentStoreCoordinator.persistentStores.contains(store))
            do {
                try graph.transaction { scoped in _ = Entity("AfterWipe", graph: scoped) }
                XCTAssertEqual(Search<Entity>(graph: graph).where(.type("AfterWipe")).sync().count, 1)
            } catch { XCTFail("Post-purge writes failed: \(error)") }
            _ = Entity("AfterWipeSync", graph: graph)
            graph.sync { success, error in
                XCTAssertTrue(success)
                XCTAssertNil(error)
            }
            done.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    func testFailedPurgeReleasesGateAndPreservesData() throws {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        _ = Entity("Retained", graph: graph)
        let container = NSPersistentCloudKitContainer(name: "PurgeTests", managedObjectModel: Model.create())
        let store = try XCTUnwrap(graph.persistentContainer?.persistentStoreCoordinator.persistentStores.first)
        let done = expectation(description: "failed purge")
        graph.purgeCloudStoreForTesting(container: container, store: store, executor: { _, _, _, callback in
            DispatchQueue.global().async { callback(nil, GraphCloudPurgeError.invalidCompletion) }
        }) { result in
            if case .success = result { XCTFail("Expected failure") }
            XCTAssertFalse(graph.isCloudPurgeInProgress)
            XCTAssertEqual(Search<Entity>(graph: graph).where(.type("Retained")).sync().count, 1)
            do { try graph.transaction { _ in } }
            catch { XCTFail("Gate not released: \(error)") }
            done.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    func testPublicPurgeIsRejectedWhileRunningUnderTests() {
        let graph = makeGraph()
        let expectation = expectation(description: "purge completion")

        graph.purgeCloudStore { result in
            guard case .failure(let error) = result else {
                return XCTFail("A real CloudKit purge must never run in unit tests")
            }
            XCTAssertEqual((error as? GraphCloudPurgeError), .notSupportedDuringTests)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testLocalConfigurationIsRejected() {
        let graph = makeGraph()
        let expectation = expectation(description: "purge completion")

        graph.validateCloudPurgeForTesting { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .cloudKitNotConfigured)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testMissingCloudContainerIsRejected() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        graph.persistentContainer = nil
        let expectation = expectation(description: "purge completion")

        graph.validateCloudPurgeForTesting { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .cloudContainerUnavailable)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testCloudContainerWithoutCloudStoreIsRejected() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        graph.persistentContainer = NSPersistentCloudKitContainer(
            name: "PurgeTests",
            managedObjectModel: Model.create()
        )
        let expectation = expectation(description: "purge completion")

        graph.validateCloudPurgeForTesting { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .cloudStoreUnavailable)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testCloudKitErrorIsPropagatedAfterOfficialCompletion() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        let container = NSPersistentCloudKitContainer(name: "PurgeTests", managedObjectModel: Model.create())
        let store = graph.persistentContainer!.persistentStoreCoordinator.persistentStores.first!
        let expected = NSError(domain: "CloudKitTests", code: 42)
        let expectation = expectation(description: "purge completion")

        graph.purgeCloudStoreForTesting(
            container: container,
            store: store,
            executor: { _, _, _, completion in completion(nil, expected) }
        ) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected CloudKit failure") }
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    func testNilZoneWithoutErrorIsNotReportedAsSuccess() {
        let graph = makeGraph(cloudKitIdentifier: "iCloud.example.tests")
        let container = NSPersistentCloudKitContainer(name: "PurgeTests", managedObjectModel: Model.create())
        let store = graph.persistentContainer!.persistentStoreCoordinator.persistentStores.first!
        let expectation = expectation(description: "purge completion")

        graph.purgeCloudStoreForTesting(
            container: container,
            store: store,
            executor: { _, _, _, completion in completion(nil, nil) }
        ) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected invalid completion") }
            XCTAssertEqual((error as? GraphCloudPurgeError), .invalidCompletion)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1)
    }

    private func makeGraph(cloudKitIdentifier: String? = nil) -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "PurgeTests-\(UUID().uuidString)"
        configuration.backend = .inMemory
        configuration.cloudKitContainerIdentifier = cloudKitIdentifier
        return Graph(configuration: configuration, migrationEnabled: false)
    }
}
