import XCTest
@testable import GraphEvo

final class StorageTests: XCTestCase {
    private func makeInMemoryGraph(_ suffix: String = UUID().uuidString) -> Graph {
        var configuration = GraphStoreConfiguration()
        configuration.name = "Storage-\(suffix)"
        configuration.backend = .inMemory
        return Graph(configuration: configuration, migrationEnabled: false)
    }

    func testAsyncSaveCompletesSuccessfullyAndPersistsChanges() {
        let graph = makeInMemoryGraph("Async")
        let entity = Entity("AsyncEntity", graph: graph)
        entity[dynamicMember: "value"] = "saved"

        let expectation = expectation(description: "async save")
        var result: (Bool, Error?)?
        graph.async { success, error in
            result = (success, error)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(result?.0, true)
        XCTAssertNil(result?.1)
        let saved = Search<Entity>(graph: graph).where(.type("AsyncEntity")).sync()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?[dynamicMember: "value"] as? String, "saved")
    }

    func testSyncCompletionCanReenterGraphAfterTheSaveReturns() {
        let graph = makeInMemoryGraph("ReentrantSync")
        let completed = expectation(description: "reentrant save completed")

        DispatchQueue.global(qos: .userInitiated).async {
            graph.sync { success, error in
                XCTAssertTrue(success, error?.localizedDescription ?? "")
                graph.sync { nestedSuccess, nestedError in
                    XCTAssertTrue(nestedSuccess, nestedError?.localizedDescription ?? "")
                    completed.fulfill()
                }
            }
        }

        wait(for: [completed], timeout: 5)
    }

    func testClearDeletesEntitiesRelationshipsAndActions() {
        let graph = makeInMemoryGraph("Clear")
        let subject = Entity("ClearEntity", graph: graph)
        let object = Entity("ClearEntity", graph: graph)
        subject.is(relationship: "knows").object = object
        subject.will(action: "message").add(objects: object)
        graph.sync()

        let expectation = expectation(description: "clear")
        graph.clear { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(Search<Entity>(graph: graph).where(.type("ClearEntity")).sync().isEmpty)
        XCTAssertTrue(Search<Relationship>(graph: graph).where(.type("knows")).sync().isEmpty)
        XCTAssertTrue(Search<Action>(graph: graph).where(.type("message")).sync().isEmpty)
    }

    func testResetDiscardsUnsavedContextChanges() {
        let graph = makeInMemoryGraph("Reset")
        _ = Entity("UnsavedEntity", graph: graph)
        XCTAssertEqual(Search<Entity>(graph: graph).where(.type("UnsavedEntity")).sync().count, 1)

        graph.reset()

        XCTAssertTrue(Search<Entity>(graph: graph).where(.type("UnsavedEntity")).sync().isEmpty)
    }

    func testStorageCallbacksReportMissingManagedContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-StorageFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "UnreadableStorage"
        configuration.location = directory
        try FileManager.default.createDirectory(at: configuration.storeURL, withIntermediateDirectories: true)
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        XCTAssertNil(graph.managedObjectContext)

        let syncExpectation = expectation(description: "sync failure")
        var syncResult: (Bool, Error?)?
        graph.sync { success, error in
            syncResult = (success, error)
            syncExpectation.fulfill()
        }
        wait(for: [syncExpectation], timeout: 2)
        XCTAssertEqual(syncResult?.0, false)
        XCTAssertNotNil(syncResult?.1)

        let asyncExpectation = expectation(description: "async failure")
        var asyncResult: (Bool, Error?)?
        graph.async { success, error in
            asyncResult = (success, error)
            asyncExpectation.fulfill()
        }
        wait(for: [asyncExpectation], timeout: 2)
        XCTAssertEqual(asyncResult?.0, false)
        XCTAssertNotNil(asyncResult?.1)
    }
}
