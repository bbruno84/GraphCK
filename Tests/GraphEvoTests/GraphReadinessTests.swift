import XCTest
import CoreData
@testable import GraphEvo

final class GraphReadinessTests: XCTestCase {
    private final class EventCollector: GraphEventDelegate {
        var events: [GraphEvent] = []
        var onEvent: ((GraphEvent) -> Void)?

        func graph(_ graph: Graph, didReceive event: GraphEvent) {
            events.append(event)
            onEvent?(event)
        }
    }

    private struct LifecycleMigration: GraphMigration {
        let id: String
        let version = 1

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            true
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(.done)
        }
    }

    private struct FailingMigration: GraphMigration {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Readiness migration failed" }
        }

        let id: String
        let version = 1

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            phase == .postInit
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(.error(ExpectedError()))
        }
    }

    func testAsyncInitializerReportsReadyAfterStoreIsUsable() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "Readiness-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let expectation = expectation(description: "Graph becomes ready")
        var graph: Graph?
        var openingGraph: Graph?

        openingGraph = Graph(
            configuration: configuration,
            migrationEnabled: false,
            onReady: { result in
                switch result {
                case .success(let readyGraph):
                    graph = readyGraph
                    XCTAssertTrue(readyGraph.isReady)
                    XCTAssertNotNil(readyGraph.managedObjectContext)
                case .failure(let error):
                    XCTFail("Unexpected readiness failure: \(error.localizedDescription)")
                }
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(graph?.isReady == true)
        withExtendedLifetime(openingGraph) {}
    }

    func testEnvironmentIsResolvedBeforeReadiness() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "Environment-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let collector = EventCollector()
        graph.eventDelegate = collector

        let readinessEvents = collector.events.compactMap { event -> GraphReadiness? in
            guard case .stateChanged(let state) = event else { return nil }
            switch state {
            case .readiness(let readiness):
                if case .ready = readiness { return readiness }
                return nil
            default: return nil
            }
        }

        XCTAssertEqual(readinessEvents.count, 1)
        XCTAssertEqual(graph.configuration.environment, .local)
    }

    func testAsyncInitializerReportsExistingStoreFailureWithoutReplacingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ReadinessFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ReadinessFailure"
        configuration.location = directory
        let storeURL = configuration.storeURL
        try createIncompatibleStore(at: storeURL)
        let originalBytes = try Data(contentsOf: storeURL)

        let expectation = expectation(description: "Graph reports failure")
        let graph = Graph(
            configuration: configuration,
            migrationEnabled: false,
            onReady: { result in
                guard case .failure(let error) = result else {
                    XCTFail("Expected the incompatible store to fail")
                    expectation.fulfill()
                    return
                }
                guard case .incompatibleStore(let reportedURL) = error else {
                    XCTFail("Unexpected readiness error: \(error.localizedDescription)")
                    expectation.fulfill()
                    return
                }
                XCTAssertEqual(reportedURL, storeURL)
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(graph.isReady)
        XCTAssertNil(graph.managedObjectContext)
        XCTAssertEqual(try Data(contentsOf: storeURL), originalBytes)
    }

    func testReadinessWaitsForMigrationLifecycle() {
        GraphMigrationManager.resetForTesting()
        defer { GraphMigrationManager.resetForTesting() }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ReadinessMigration-\(UUID().uuidString)"
        configuration.backend = .inMemory
        GraphMigrationManager.registerMigration(
            LifecycleMigration(id: "ReadinessMigration-\(UUID().uuidString)")
        )

        let expectation = expectation(description: "Graph lifecycle becomes ready")
        let graph = Graph(
            configuration: configuration,
            migrationEnabled: true,
            onReady: { result in
                guard case .success(let readyGraph) = result else {
                    XCTFail("Unexpected migration readiness failure")
                    expectation.fulfill()
                    return
                }
                XCTAssertTrue(readyGraph.isReady)
                XCTAssertNotNil(readyGraph.managedObjectContext)
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(graph.isReady)
    }

    func testFailedMigrationDoesNotMaskUsableStoreReadiness() {
        GraphMigrationManager.resetForTesting()
        defer { GraphMigrationManager.resetForTesting() }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ReadinessMigrationFailure-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migrationID = "ReadinessMigrationFailure-\(UUID().uuidString)"
        GraphMigrationManager.registerMigration(FailingMigration(id: migrationID))

        let graph = Graph(configuration: configuration, migrationEnabled: true)
        let collector = EventCollector()
        graph.eventDelegate = collector

        let expectation = expectation(description: "Graph remains ready after migration failure")
        graph.whenReady { result in
            guard case .success(let readyGraph) = result else {
                XCTFail("A migration failure must not be reported as store opening failure")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(readyGraph.isReady)
            XCTAssertNotNil(readyGraph.managedObjectContext)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(graph.isReady)
        XCTAssertTrue(collector.events.contains { event in
            guard case .error(.migration(let id, _, _)) = event else { return false }
            return id == migrationID
        })
        XCTAssertTrue(collector.events.contains { event in
            if case .stateChanged(.readiness(.ready)) = event { return true }
            return false
        })
        XCTAssertFalse(collector.events.contains { event in
            if case .stateChanged(.readiness(.failed)) = event { return true }
            return false
        })
    }

    func testAutomaticLifecycleIncludesPostMigrationBeforeReady() {
        GraphMigrationManager.resetForTesting()
        defer { GraphMigrationManager.resetForTesting() }
        var phases: [GraphMigrationManager.GraphLifecyclePhase] = []
        for phase in [GraphMigrationManager.GraphLifecyclePhase.preInit, .postInit, .postMigration, .ready] {
            GraphMigrationManager.registerCallback(for: phase) { _, _ in phases.append(phase) }
        }
        var configuration = GraphStoreConfiguration()
        configuration.name = "LifecycleOrder-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let graph = Graph(configuration: configuration)
        let ready = expectation(description: "ready")
        graph.whenReady { _ in ready.fulfill() }
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(phases.count, 4)
        if phases.count == 4 {
            if case .preInit = phases[0] {} else { XCTFail("Expected preInit first") }
            if case .postInit = phases[1] {} else { XCTFail("Expected postInit second") }
            if case .postMigration = phases[2] {} else { XCTFail("Expected postMigration third") }
            if case .ready = phases[3] {} else { XCTFail("Expected ready last") }
        }
    }

    func testEventDelegateReceivesPersistenceAndReadinessStates() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "Events-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let readyExpectation = expectation(description: "Ready event delivered")
        let localModeExpectation = expectation(description: "Local persistence event delivered")
        let collector = EventCollector()
        collector.onEvent = { event in
            switch event {
            case .stateChanged(.readiness(.ready)):
                readyExpectation.fulfill()
            case .stateChanged(.persistenceMode(.local)):
                localModeExpectation.fulfill()
            default:
                break
            }
        }

        let graph = Graph(configuration: configuration, migrationEnabled: false)
        graph.eventDelegate = collector

        wait(for: [readyExpectation, localModeExpectation], timeout: 2)
        XCTAssertTrue(collector.events.contains {
            if case .stateChanged(.readiness(.ready)) = $0 { return true }
            return false
        })
    }

    func testEventDelegateReceivesStoreOpeningFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-EventFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "EventFailure"
        configuration.location = directory
        try createIncompatibleStore(at: configuration.storeURL)

        let failureExpectation = expectation(description: "Opening error delivered")
        let collector = EventCollector()
        collector.onEvent = { event in
            guard case .error(.storeOpening(.incompatibleStore)) = event else { return }
            failureExpectation.fulfill()
        }

        let graph = Graph(configuration: configuration, migrationEnabled: false)
        graph.eventDelegate = collector

        wait(for: [failureExpectation], timeout: 2)
        XCTAssertFalse(graph.isReady)
    }

    func testPersistentHistoryAuthorWarningUsesEventChannel() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "MissingAuthorWarning-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let collector = EventCollector()
        graph.eventDelegate = collector

        graph.emit(.warning(.persistentHistoryMissingTransactionAuthor))

        XCTAssertTrue(collector.events.contains { event in
            if case .warning(.persistentHistoryMissingTransactionAuthor) = event { return true }
            return false
        })
    }

    private func createIncompatibleStore(at url: URL) throws {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "LegacyEntity"
        entity.managedObjectClassName = "NSManagedObject"
        let attribute = NSAttributeDescription()
        attribute.name = "legacyValue"
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = true
        entity.properties = [attribute]
        model.entities = [entity]

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: url,
            options: [:]
        )
        try coordinator.remove(store)
    }
}
