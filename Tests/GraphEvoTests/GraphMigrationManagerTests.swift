import XCTest
import CoreData
@testable import GraphEvo

final class GraphMigrationManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GraphMigrationManager.resetForTesting()
    }

    private struct CompletingMigration: GraphMigration {
        let id: String
        let version = 1
        let shouldRun: (GraphMigrationManager.GraphLifecyclePhase) -> Bool

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            shouldRun(phase)
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

    private struct ResultMigration: GraphMigration {
        let id: String
        let result: GraphMigrationResult

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
            completion(result)
        }
    }

    private final class RemoteTrackingMigration: GraphMigration {
        let id: String
        private(set) var insertedIDs: [NSManagedObjectID] = []
        private(set) var updatedIDs: [NSManagedObjectID] = []

        init(id: String) {
            self.id = id
        }

        func needsRun(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: inout GraphMigrationContext?
        ) -> Bool {
            false
        }

        func handlePhase(
            _ phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            completion: @escaping (GraphMigrationResult) -> Void
        ) {
            completion(.skipped)
        }

        func handleRemoteChanges(
            configuration: GraphStoreConfiguration?,
            graph: Graph?,
            context: GraphMigrationContext?,
            inserted: [NSManagedObjectID],
            updated: [NSManagedObjectID]
        ) {
            insertedIDs = inserted
            updatedIDs = updated
        }
    }

    private final class LifecycleMigration: GraphMigration {
        let id: String
        let result: GraphMigrationResult
        let adoptsLegacyCompletion: Bool
        private(set) var handleCount = 0

        init(id: String, result: GraphMigrationResult = .done, adoptsLegacyCompletion: Bool = false) {
            self.id = id
            self.result = result
            self.adoptsLegacyCompletion = adoptsLegacyCompletion
        }

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
            handleCount += 1
            completion(result)
        }

        func recognizesLegacyCompletion(
            at phase: GraphMigrationManager.GraphLifecyclePhase,
            configuration: GraphStoreConfiguration?,
            graph: Graph?
        ) -> Bool {
            adoptsLegacyCompletion
        }
    }

    private final class DelayedMigration: GraphMigration {
        let id: String
        private let lock = NSLock()
        private(set) var handledPhases: [GraphMigrationManager.GraphLifecyclePhase] = []
        let preInitDelay: TimeInterval
        let onCompleted: ((GraphMigrationManager.GraphLifecyclePhase) -> Void)?

        init(
            id: String,
            preInitDelay: TimeInterval = 0.05,
            onCompleted: ((GraphMigrationManager.GraphLifecyclePhase) -> Void)? = nil
        ) {
            self.id = id
            self.preInitDelay = preInitDelay
            self.onCompleted = onCompleted
        }

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
            lock.lock()
            handledPhases.append(phase)
            lock.unlock()

            let delay = phase == .preInit ? preInitDelay : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                completion(.done)
                self.onCompleted?(phase)
            }
        }

        var phases: [GraphMigrationManager.GraphLifecyclePhase] {
            lock.lock()
            defer { lock.unlock() }
            return handledPhases
        }
    }

    private final class ParallelMigration: GraphMigration {
        let id: String
        private let lock = NSLock()
        private var completions: [(GraphMigrationResult) -> Void] = []
        private(set) var storeNames: Set<String> = []

        init(id: String) { self.id = id }

        func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool {
            phase == .postInit
        }

        func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) {
            lock.lock()
            storeNames.insert(configuration?.name ?? "unknown")
            completions.append(completion)
            let pending = completions.count == 2 ? completions : []
            if pending.count == 2 { completions.removeAll() }
            lock.unlock()
            pending.forEach { $0(.done) }
        }
    }

    func testAsyncPhaseQueuesLaterLifecyclePhaseWithoutOverwritingState() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerAsync-\(UUID().uuidString)"
        configuration.backend = .inMemory

        let readyExpectation = expectation(description: "ready migration completes")
        let migration = DelayedMigration(
            id: "ManagerAsync-\(UUID().uuidString)",
            onCompleted: { phase in
                if case .ready = phase {
                    readyExpectation.fulfill()
                }
            }
        )
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.preInit, configuration: configuration, graph: nil)
        GraphMigrationManager.handlePhase(.ready, configuration: configuration, graph: nil)

        wait(for: [readyExpectation], timeout: 2)
        let phases = migration.phases
        XCTAssertEqual(phases.count, 2)
        if phases.count == 2 {
            if case .preInit = phases[0] {
                // Expected first phase.
            } else {
                XCTFail("The asynchronous preInit phase was not completed first")
            }
            if case .ready = phases[1] {
                // Expected queued phase.
            } else {
                XCTFail("The queued ready phase was not started after preInit")
            }
        }
        XCTAssertEqual(
            GraphMigrationManager.record(for: migration, configuration: configuration)?.state,
            .done
        )
    }

    func testRegisteredMigrationRunsOnceAndPersistsCompletion() throws {
        let migrationID = "ManagerTest-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-Manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerTest"
        configuration.location = directory

        let migration = CompletingMigration(id: migrationID) { $0 == .preInit }
        GraphMigrationManager.registerMigration(migration)
        GraphMigrationManager.handlePhase(.preInit, configuration: configuration, graph: nil)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .started)

        GraphMigrationManager.handlePhase(.ready, configuration: configuration, graph: nil)

        let record = GraphMigrationManager.record(for: migration, configuration: configuration)
        XCTAssertEqual(record?.state, .done)
        XCTAssertEqual(record?.migrationID, migrationID)
        XCTAssertEqual(record?.version, 1)

        try GraphMigrationManager.resetRecord(for: migration, configuration: configuration)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .notExecuted)
    }

    func testMigrationContextStoresTypedValues() {
        var context = GraphMigrationContext()
        context.set("count", value: 3)
        context.set("name", value: "migration")

        XCTAssertEqual(context["count"] as Int?, 3)
        XCTAssertEqual(context["name"] as String?, "migration")
        XCTAssertNil(context["missing"] as String?)
    }

    func testFailedMigrationPersistsErrorAndPostsFailureNotification() throws {
        struct ExpectedError: LocalizedError {
            var errorDescription: String? { "Manager test failed" }
        }

        let migrationID = "ManagerFailure-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerFailure"
        configuration.location = directory

        let migration = ResultMigration(id: migrationID, result: .error(ExpectedError()))
        GraphMigrationManager.registerMigration(migration)
        let notificationExpectation = expectation(description: "failure notification")
        var failureInfo: GraphMigrationManager.FailureInfo?
        let observer = GraphMigrationManager.observeMigrationFailure { info in
            guard info.migrationID == migrationID else { return }
            failureInfo = info
            notificationExpectation.fulfill()
        }
        defer { GraphMigrationManager.removeProgressObserver(observer) }

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)
        wait(for: [notificationExpectation], timeout: 1)

        let record = try XCTUnwrap(GraphMigrationManager.record(for: migration, configuration: configuration))
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.errorDescription, "Manager test failed")
        XCTAssertEqual(failureInfo?.migrationID, migrationID)
        XCTAssertEqual(failureInfo?.errorDescription, "Manager test failed")
        if case .postInit? = failureInfo?.phase {
            // Expected lifecycle phase.
        } else {
            XCTFail("Failure notification reported the wrong phase")
        }
    }

    func testSkippedMigrationClearsStartedRecord() throws {
        let migrationID = "ManagerSkipped-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerSkipped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerSkipped"
        configuration.location = directory

        let migration = ResultMigration(id: migrationID, result: .skipped)
        GraphMigrationManager.registerMigration(migration)
        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .notRequired)
    }

    func testRemoteEntityChangesAreForwardedToRegisteredMigrations() throws {
        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerRemote-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let graph = Graph(configuration: configuration, migrationEnabled: false)
        let entity = Entity("RemoteEntity", graph: graph)
        let objectID = entity.managedNode.objectID
        let migration = RemoteTrackingMigration(id: "ManagerRemote-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handleRemoteEntityChanges(
            configuration: configuration,
            graph: graph,
            inserted: [objectID],
            updated: []
        )

        XCTAssertEqual(migration.insertedIDs, [objectID])
        XCTAssertTrue(migration.updatedIDs.isEmpty)
    }

    func testDefaultMigrationHelpersAndLedgerReconciliation() throws {
        let migrationID = "ManagerDefaults-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerDefaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerDefaults"
        configuration.location = directory
        let migration = CompletingMigration(id: migrationID) { _ in false }
        let record = try GraphMigrationLedger.markDone(
            migrationID: migrationID,
            version: migration.version,
            synchronization: .local,
            configuration: configuration
        )

        var context = GraphMigrationContext()
        context.set("GraphMigration.previousRecord", value: record)
        XCTAssertEqual(context.previousMigrationRecord, record)
        XCTAssertEqual(
            migration.backupRoot(for: configuration),
            GraphMigrationManager.defaultBackupRoot(for: configuration)
        )

        let reconciled = GraphMigrationLedger.reconciledRecord(
            migrationID: migrationID,
            version: migration.version,
            synchronization: .localAndICloudKeyValueStore,
            configuration: configuration
        )
        XCTAssertEqual(reconciled?.migrationID, record.migrationID)
        XCTAssertEqual(reconciled?.version, record.version)
        XCTAssertEqual(reconciled?.state, .done)

        migration.resetMigrationState(for: configuration)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .notExecuted)
    }

    func testAlreadyCompletedMigrationIsNotExecutedAgain() throws {
        let migrationID = "ManagerAlreadyDone-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerAlreadyDone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerAlreadyDone"
        configuration.location = directory
        let migration = LifecycleMigration(id: migrationID)
        _ = try GraphMigrationLedger.markDone(
            migrationID: migrationID,
            version: migration.version,
            synchronization: .local,
            configuration: configuration
        )
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 0)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .done)
    }

    func testLegacyCompletionIsAdoptedWithoutCallingMigrationHandler() throws {
        let migrationID = "ManagerLegacyDone-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerLegacyDone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerLegacyDone"
        configuration.location = directory
        let migration = LifecycleMigration(id: migrationID, adoptsLegacyCompletion: true)
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 0)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .done)
    }

    func testFallbackResultIsPersistedAsDone() throws {
        let migrationID = "ManagerFallback-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ManagerFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ManagerFallback"
        configuration.location = directory
        let migration = LifecycleMigration(id: migrationID, result: .fallback)
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 1)
        XCTAssertEqual(GraphMigrationManager.record(for: migration, configuration: configuration)?.state, .done)
    }

    func testPersistentAttemptRecordsBackupReferenceBeforeCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphEvo-ManagerBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("GraphEvo_Backup.sqlite")
        try Data("sqlite-test".utf8).write(to: storeURL)

        var configuration = GraphStoreConfiguration()
        configuration.name = "Backup"
        configuration.location = storeURL
        let migration = LifecycleMigration(id: "ManagerBackup-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)
        GraphMigrationManager.handlePhase(.preInit, configuration: configuration, graph: nil)
        GraphMigrationManager.handlePhase(.ready, configuration: configuration, graph: nil)

        let snapshot = GraphMigrationLedger.snapshot(migrationID: migration.id, version: migration.version, configuration: configuration)
        XCTAssertEqual(snapshot?.current.state, .done)
        XCTAssertNotNil(snapshot?.latestEntry?.backupReference)
    }

    func testCompletedScopeReleasesItsCoordinator() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "CoordinatorRelease-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migration = CompletingMigration(id: "CoordinatorRelease") { $0 == .postInit }
        GraphMigrationManager.registerMigration(migration)
        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)
        XCTAssertEqual(GraphMigrationManager.coordinatorCountForTesting, 0)
    }

    func testForcedAttemptPreservesRequestOriginThroughCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraphEvo-ForceOrigin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = GraphStoreConfiguration()
        configuration.name = "ForceOrigin"
        configuration.location = directory
        let migration = LifecycleMigration(id: "ForceOrigin-\(UUID().uuidString)")
        try GraphMigrationManager.forceMigration(
            migration,
            configuration: configuration,
            requestedBy: .supportCenter,
            reason: "diagnostic retry"
        )
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        let history = try GraphMigrationManager.history(for: migration, configuration: configuration)
        XCTAssertEqual(history.last?.state, .done)
        XCTAssertEqual(history.last?.requestedBy, .supportCenter)
        XCTAssertTrue(history.contains { $0.source == "forceRequest" && $0.requestReason == "diagnostic retry" })
    }

    func testForceRunsEvenWhenNormalNeedsRunDecisionIsFalse() throws {
        final class NormallySkippedMigration: GraphMigration {
            let id: String
            private(set) var handleCount = 0
            init(id: String) { self.id = id }
            func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool { false }
            func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) {
                handleCount += 1
                completion(.done)
            }
        }
        var configuration = GraphStoreConfiguration()
        configuration.name = "ForcedNeedsRun-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migration = NormallySkippedMigration(id: "ForcedNeedsRun-\(UUID().uuidString)")
        try GraphMigrationManager.forceMigration(migration, configuration: configuration, reason: "test override")
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.handleCount, 1)
        XCTAssertEqual(try GraphMigrationManager.stateSnapshot(for: migration, configuration: configuration).localRecord?.state, .done)
    }

    func testInterruptedAttemptWaitsForItsRecordedPhaseBeforeRecoveryDecision() throws {
        final class RecoveryMigration: GraphMigration {
            let id: String
            var evaluatedPhases: [GraphMigrationManager.GraphLifecyclePhase] = []
            init(id: String) { self.id = id }
            func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool {
                evaluatedPhases.append(phase)
                XCTAssertTrue(context?.migrationStateSnapshot?.interrupted == true)
                return false
            }
            func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) { XCTFail("Recovered data was already compatible"); completion(.done) }
        }
        var configuration = GraphStoreConfiguration()
        configuration.name = "RecoveryPhase-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migration = RecoveryMigration(id: "RecoveryPhase")
        _ = try GraphMigrationLedger.markStarted(migrationID: migration.id, version: migration.version, configuration: configuration, phase: "ready", operationID: "interrupted", generation: 3)
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.preInit, configuration: configuration, graph: nil)
        XCTAssertTrue(migration.evaluatedPhases.isEmpty)
        XCTAssertEqual(GraphMigrationLedger.localRecord(migrationID: migration.id, version: migration.version, configuration: configuration)?.state, .started)

        GraphMigrationManager.handlePhase(.ready, configuration: configuration, graph: nil)
        XCTAssertEqual(migration.evaluatedPhases.count, 1)
        let recovered = try XCTUnwrap(GraphMigrationManager.history(for: migration, configuration: configuration).last)
        XCTAssertEqual(recovered.state, .notRequired)
        XCTAssertEqual(recovered.decisionReason, .alreadyCompatible)
        XCTAssertEqual(recovered.decisionSource, .recovery)
    }

    func testInterruptedAttemptCreatesANewAttemptWhenNeedsRunRemainsTrue() throws {
        let migration = CompletingMigration(id: "RecoveryRetry") { $0 == .postInit }
        var configuration = GraphStoreConfiguration()
        configuration.name = "RecoveryRetry-\(UUID().uuidString)"
        configuration.backend = .inMemory
        _ = try GraphMigrationLedger.markStarted(migrationID: migration.id, version: migration.version, configuration: configuration, phase: "postInit", operationID: "interrupted", generation: 8)
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        let history = try GraphMigrationManager.history(for: migration, configuration: configuration)
        XCTAssertEqual(history.last?.state, .done)
        XCTAssertGreaterThan(history.last?.generation ?? 0, 8)
        XCTAssertNotEqual(history.last?.operationID, "interrupted")
    }

    func testKVSObserverReconcilesRemoteProjectionEndToEnd() throws {
        struct SharedMigration: GraphMigration {
            let id: String
            var completionSynchronization: GraphMigrationCompletionSynchronization { .localAndICloudKeyValueStore }
            func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool { false }
            func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) { completion(.skipped) }
        }
        let store = TestMigrationKVSStore()
        GraphMigrationLedger.setKVSStoreForTesting(store)
        let publisherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let observerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: publisherRoot); try? FileManager.default.removeItem(at: observerRoot) }
        var publisher = GraphStoreConfiguration()
        publisher.name = "ObserverScope"
        publisher.location = publisherRoot.appendingPathComponent("store")
        var observer = publisher
        observer.location = observerRoot.appendingPathComponent("store")
        let migration = SharedMigration(id: "ObserverMigration")
        GraphMigrationManager.registerMigration(migration)
        _ = try GraphMigrationLedger.markDone(migrationID: migration.id, version: migration.version, synchronization: .localAndICloudKeyValueStore, configuration: publisher, operationID: "remote-operation", generation: 4)
        try GraphMigrationLedger.retryPendingPublicationForTesting(migrationID: migration.id, version: migration.version, configuration: publisher)

        GraphMigrationManager.registerKVSObservation(configuration: observer)
        NotificationCenter.default.post(name: store.changeNotification, object: store)

        let snapshot = try GraphMigrationManager.stateSnapshot(for: migration, configuration: observer)
        guard case .observed(let remote) = snapshot.remoteState else { return XCTFail("Expected observed remote state") }
        XCTAssertEqual(remote.state, .done)
        XCTAssertTrue(try GraphMigrationManager.history(for: migration, configuration: observer).contains { $0.source == "remoteKVS" && $0.observedAt != nil })
        GraphMigrationManager.handlePhase(.postInit, configuration: observer, graph: nil)
        let decision = try XCTUnwrap(GraphMigrationManager.history(for: migration, configuration: observer).last)
        XCTAssertEqual(decision.state, .notRequired)
        XCTAssertEqual(decision.decisionReason, .remoteDone)
        XCTAssertEqual(decision.decisionSource, .remoteKVS)
        GraphMigrationManager.unregisterKVSObservation(configuration: observer)
    }

    func testAdvancedResetAPIRecordsAllTargetsAndDiagnostics() throws {
        GraphMigrationLedger.setKVSStoreForTesting(TestMigrationKVSStore())
        var configuration = GraphStoreConfiguration()
        configuration.name = "ResetDiagnostics-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migration = CompletingMigration(id: "ResetDiagnostics-\(UUID().uuidString)") { _ in false }

        try GraphMigrationManager.resetRecord(
            for: migration,
            configuration: configuration,
            targets: [.local, .remote],
            requestedBy: .supportCenter,
            reason: "repair projection"
        )

        let snapshot = try GraphMigrationManager.stateSnapshot(for: migration, configuration: configuration)
        XCTAssertEqual(snapshot.localRecord?.state, .notExecuted)
        let history = try GraphMigrationManager.history(for: migration, configuration: configuration)
        XCTAssertEqual(history.last?.resetTargets, [.local, .remote])
        XCTAssertEqual(history.last?.requestedBy, .supportCenter)
        XCTAssertEqual(history.last?.requestReason, "repair projection")
    }

    func testKVSObservationLifetimeIsReferenceCountedPerStore() {
        var configuration = GraphStoreConfiguration()
        configuration.name = "KVSObserver-\(UUID().uuidString)"
        configuration.backend = .inMemory

        GraphMigrationManager.registerKVSObservation(configuration: configuration)
        GraphMigrationManager.registerKVSObservation(configuration: configuration)
        XCTAssertEqual(GraphMigrationManager.observedStoreCountForTesting, 1)

        GraphMigrationManager.unregisterKVSObservation(configuration: configuration)
        XCTAssertEqual(GraphMigrationManager.observedStoreCountForTesting, 1)
        GraphMigrationManager.unregisterKVSObservation(configuration: configuration)
        XCTAssertEqual(GraphMigrationManager.observedStoreCountForTesting, 0)
    }

    func testDifferentStoreCoordinatorsCanRunInParallel() {
        var first = GraphStoreConfiguration()
        first.name = "Parallel-A-\(UUID().uuidString)"
        first.backend = .inMemory
        var second = GraphStoreConfiguration()
        second.name = "Parallel-B-\(UUID().uuidString)"
        second.backend = .inMemory
        let migration = ParallelMigration(id: "Parallel-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)
        let firstDone = expectation(description: "first store completed")
        let secondDone = expectation(description: "second store completed")

        GraphMigrationManager.handlePhase(.postInit, configuration: first, graph: nil) { firstDone.fulfill() }
        GraphMigrationManager.handlePhase(.postInit, configuration: second, graph: nil) { secondDone.fulfill() }

        wait(for: [firstDone, secondDone], timeout: 1)
        XCTAssertEqual(migration.storeNames, [first.name, second.name])
        XCTAssertEqual(GraphMigrationManager.coordinatorCountForTesting, 0)
    }

    func testFailureInOneStoreDoesNotBlockAnotherStore() throws {
        final class StoreSelectiveMigration: GraphMigration {
            let id: String
            init(id: String) { self.id = id }
            func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool { phase == .postInit }
            func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) {
                if configuration?.name.hasPrefix("Failing") == true { completion(.error(NSError(domain: "isolated", code: 1))) }
                else { completion(.done) }
            }
        }
        var failing = GraphStoreConfiguration()
        failing.name = "Failing-\(UUID().uuidString)"
        failing.backend = .inMemory
        var succeeding = GraphStoreConfiguration()
        succeeding.name = "Succeeding-\(UUID().uuidString)"
        succeeding.backend = .inMemory
        let migration = StoreSelectiveMigration(id: "StoreIsolation-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: failing, graph: nil)
        GraphMigrationManager.handlePhase(.postInit, configuration: succeeding, graph: nil)

        XCTAssertEqual(try GraphMigrationManager.stateSnapshot(for: migration, configuration: failing).localRecord?.state, .failed)
        XCTAssertEqual(try GraphMigrationManager.stateSnapshot(for: migration, configuration: succeeding).localRecord?.state, .done)
    }

    func testLateDuplicateCompletionCannotChangeTerminalState() throws {
        final class DuplicateCompletionMigration: GraphMigration {
            let id: String
            init(id: String) { self.id = id }
            func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool { phase == .postInit }
            func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) {
                completion(.done)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                    completion(.error(NSError(domain: "late", code: 1)))
                }
            }
        }
        var configuration = GraphStoreConfiguration()
        configuration.name = "LateCompletion-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migration = DuplicateCompletionMigration(id: "LateCompletion-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)
        let delay = expectation(description: "late callback delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { delay.fulfill() }
        wait(for: [delay], timeout: 1)

        XCTAssertEqual(try GraphMigrationManager.stateSnapshot(for: migration, configuration: configuration).localRecord?.state, .done)
    }

    func testFailedMigrationCanBeRetriedInAReusedScope() throws {
        final class RetryingMigration: GraphMigration {
            let id: String
            private(set) var attempts = 0
            init(id: String) { self.id = id }
            func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: inout GraphMigrationContext?) -> Bool { phase == .postInit }
            func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, context: GraphMigrationContext?, completion: @escaping (GraphMigrationResult) -> Void) {
                attempts += 1
                if attempts == 1 { completion(.error(NSError(domain: "retry", code: 1))) }
                else { completion(.done) }
            }
        }
        var configuration = GraphStoreConfiguration()
        configuration.name = "Retry-\(UUID().uuidString)"
        configuration.backend = .inMemory
        let migration = RetryingMigration(id: "Retry-\(UUID().uuidString)")
        GraphMigrationManager.registerMigration(migration)

        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)
        XCTAssertEqual(try GraphMigrationManager.stateSnapshot(for: migration, configuration: configuration).localRecord?.state, .failed)
        GraphMigrationManager.handlePhase(.postInit, configuration: configuration, graph: nil)

        XCTAssertEqual(migration.attempts, 2)
        XCTAssertEqual(try GraphMigrationManager.stateSnapshot(for: migration, configuration: configuration).localRecord?.state, .done)
    }
}
